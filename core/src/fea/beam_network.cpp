#include "topopt/beam_network.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <array>
#include <map>
#include <string>
#include <chrono>
#include <numeric>
#include <functional>
#include <set>
#include <stdexcept>

namespace topopt {
namespace {

constexpr double kWeldEps = 1e-6;  // mm; exact-coincidence tolerance

struct DisjointSet {
  std::vector<int> parent;
  explicit DisjointSet(std::size_t n) : parent(n) {
    std::iota(parent.begin(), parent.end(), 0);
  }
  int find(int x) {
    while (parent[static_cast<std::size_t>(x)] != x) {
      parent[static_cast<std::size_t>(x)] =
          parent[static_cast<std::size_t>(parent[static_cast<std::size_t>(x)])];
      x = parent[static_cast<std::size_t>(x)];
    }
    return x;
  }
  void unite(int a, int b) {
    a = find(a); b = find(b);
    if (a != b) parent[static_cast<std::size_t>(std::max(a, b))] = std::min(a, b);
  }
};

double dist(const Vec3& a, const Vec3& b) {
  const double dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
  return std::sqrt(dx * dx + dy * dy + dz * dz);
}

}  // namespace

BeamNetwork build_beam_network(const std::vector<BeamSegment>& segments) {
  for (const BeamSegment& s : segments)
    if (!(s.radius_mm > 0.0))
      throw std::invalid_argument("build_beam_network: radius must be > 0");

  // Pass 1: weld EXACT coincidences into provisional nodes.
  std::map<std::array<long long, 3>, int> key_to_id;
  std::vector<Vec3> pts;
  std::vector<double> rad;
  auto id_of = [&](const Vec3& p, double r) {
    const std::array<long long, 3> k{
        static_cast<long long>(std::llround(p.x / kWeldEps)),
        static_cast<long long>(std::llround(p.y / kWeldEps)),
        static_cast<long long>(std::llround(p.z / kWeldEps))};
    auto it = key_to_id.find(k);
    if (it != key_to_id.end()) {
      rad[static_cast<std::size_t>(it->second)] =
          std::max(rad[static_cast<std::size_t>(it->second)], r);
      return it->second;
    }
    const int id = static_cast<int>(pts.size());
    key_to_id.emplace(k, id);
    pts.push_back(p);
    rad.push_back(r);
    return id;
  };
  struct Raw { int a, b; double r; };
  std::vector<Raw> raw;
  raw.reserve(segments.size());
  for (const BeamSegment& s : segments) {
    const int a = id_of(s.a, s.radius_mm), b = id_of(s.b, s.radius_mm);
    if (a != b) raw.push_back({a, b, s.radius_mm});
  }

  // Pass 2: label the CHAINS produced by pass 1, so the contact weld can be
  // restricted to pairs from DIFFERENT chains. Without that restriction the weld
  // collapses each traced curve, whose consecutive vertices are closer than r+r.
  DisjointSet chain(pts.size());
  for (const Raw& e : raw) chain.unite(e.a, e.b);

  // Pass 3: weld CONTACT pairs across chains. Bucketed by the largest contact
  // radius so the pairwise test stays local.
  const double cell =
      2.0 * (rad.empty() ? 1.0 : *std::max_element(rad.begin(), rad.end()));
  std::map<std::array<long long, 3>, std::vector<int>> bins;
  auto bin_key = [&](const Vec3& p) {
    return std::array<long long, 3>{
        static_cast<long long>(std::floor(p.x / cell)),
        static_cast<long long>(std::floor(p.y / cell)),
        static_cast<long long>(std::floor(p.z / cell))};
  };
  for (int i = 0; i < static_cast<int>(pts.size()); ++i)
    bins[bin_key(pts[static_cast<std::size_t>(i)])].push_back(i);

  DisjointSet weld(pts.size());
  for (const auto& kv : bins) {
    for (long long dz = -1; dz <= 1; ++dz)
      for (long long dy = -1; dy <= 1; ++dy)
        for (long long dx = -1; dx <= 1; ++dx) {
          auto it = bins.find({kv.first[0] + dx, kv.first[1] + dy, kv.first[2] + dz});
          if (it == bins.end()) continue;
          for (int i : kv.second)
            for (int j : it->second) {
              if (i >= j) continue;
              if (chain.find(i) == chain.find(j)) continue;   // same curve: never
              const double lim = rad[static_cast<std::size_t>(i)] +
                                 rad[static_cast<std::size_t>(j)];
              if (dist(pts[static_cast<std::size_t>(i)],
                       pts[static_cast<std::size_t>(j)]) <= lim)
                weld.unite(i, j);
            }
        }
  }

  // Pass 4: renumber, averaging the welded positions.
  std::map<int, int> root_to_new;
  for (int i = 0; i < static_cast<int>(pts.size()); ++i) {
    const int r = weld.find(i);
    if (root_to_new.find(r) == root_to_new.end()) {
      const int n = static_cast<int>(root_to_new.size());
      root_to_new.emplace(r, n);
    }
  }
  BeamNetwork net;
  net.nodes.assign(root_to_new.size(), Vec3{0.0, 0.0, 0.0});
  std::vector<double> count(root_to_new.size(), 0.0);
  for (int i = 0; i < static_cast<int>(pts.size()); ++i) {
    const int n = root_to_new[weld.find(i)];
    net.nodes[static_cast<std::size_t>(n)].x += pts[static_cast<std::size_t>(i)].x;
    net.nodes[static_cast<std::size_t>(n)].y += pts[static_cast<std::size_t>(i)].y;
    net.nodes[static_cast<std::size_t>(n)].z += pts[static_cast<std::size_t>(i)].z;
    count[static_cast<std::size_t>(n)] += 1.0;
  }
  for (std::size_t n = 0; n < net.nodes.size(); ++n) {
    net.nodes[n].x /= count[n];
    net.nodes[n].y /= count[n];
    net.nodes[n].z /= count[n];
  }
  for (const Raw& e : raw) {
    const int a = root_to_new[weld.find(e.a)], b = root_to_new[weld.find(e.b)];
    if (a == b) continue;
    if (dist(net.nodes[static_cast<std::size_t>(a)],
             net.nodes[static_cast<std::size_t>(b)]) <= kWeldEps)
      continue;  // welding averaged the two ends onto the same point
    net.members.push_back({a, b, e.r});
  }
  return net;
}

BeamRestraintReport beam_network_restraint(
    const BeamNetwork& net, const std::vector<char>& node_tied,
    const std::vector<char>* node_welded) {
  if (node_tied.size() != net.nodes.size())
    throw std::invalid_argument("beam_network_restraint: node_tied size mismatch");

  BeamRestraintReport rep;
  rep.members_total = net.members.size();
  rep.member_unrestrained.assign(net.members.size(), 0);
  rep.member_load_free.assign(net.members.size(), 0);
  rep.member_underconstrained.assign(net.members.size(), 0);
  for (char t : node_tied) rep.nodes_tied += (t != 0) ? 1u : 0u;

  // Node degree within the network.
  std::vector<int> degree(net.nodes.size(), 0);
  for (const BeamNetwork::Member& m : net.members) {
    ++degree[static_cast<std::size_t>(m.node_a)];
    ++degree[static_cast<std::size_t>(m.node_b)];
  }

  // A member is RESTRAINED when each of its ends is either tied to solid or shares
  // a node with another member (which supplies the missing moment through the frame
  // element's own bending stiffness). An end that is neither is a free spin — the
  // exact mechanism test_frame_element proves a pinned tie leaves behind.
  for (std::size_t i = 0; i < net.members.size(); ++i) {
    const BeamNetwork::Member& m = net.members[i];
    const bool a_ok = node_tied[static_cast<std::size_t>(m.node_a)] != 0 ||
                      degree[static_cast<std::size_t>(m.node_a)] > 1;
    const bool b_ok = node_tied[static_cast<std::size_t>(m.node_b)] != 0 ||
                      degree[static_cast<std::size_t>(m.node_b)] > 1;
    if (!a_ok && !b_ok) {
      rep.member_unrestrained[i] = 1;
      ++rep.members_unrestrained;
    }
  }

  // Components, and whether each reaches a tie at all. A component with no tie
  // carries no load however well its members are connected to each other.
  // ★ COMPONENTS ARE COUNTED OVER MEMBERS, NOT OVER NODES. A node attached to
  // nothing is a leftover, not a lattice component -- and dropping members leaves
  // exactly such nodes behind. Counting them inflated a real part's components from
  // 385 to 3,203 after one prune, turning a converging problem into a phantom one.
  DisjointSet comp(net.nodes.size());
  for (const BeamNetwork::Member& m : net.members) comp.unite(m.node_a, m.node_b);
  std::vector<char> node_has_member(net.nodes.size(), 0);
  for (const BeamNetwork::Member& m : net.members) {
    node_has_member[static_cast<std::size_t>(m.node_a)] = 1;
    node_has_member[static_cast<std::size_t>(m.node_b)] = 1;
  }
  std::map<int, bool> root_has_tie;
  for (std::size_t n = 0; n < net.nodes.size(); ++n) {
    if (!node_has_member[n]) continue;          // no member: not a component
    const int r = comp.find(static_cast<int>(n));
    auto it = root_has_tie.find(r);
    const bool tied = node_tied[n] != 0;
    if (it == root_has_tie.end()) root_has_tie.emplace(r, tied);
    else it->second = it->second || tied;
  }
  for (const auto& kv : root_has_tie) {
    ++rep.components_total;
    if (!kv.second) ++rep.components_unrestrained;
  }
  for (std::size_t i = 0; i < net.members.size(); ++i) {
    const int r = comp.find(net.members[i].node_a);
    const auto it = root_has_tie.find(r);
    if (it != root_has_tie.end() && !it->second) rep.member_load_free[i] = 1;
  }

  // ★ THREE NON-COLLINEAR TIES PER COMPONENT. Gather each component's tied points
  // and test that they span a plane, not a line or a point.
  std::set<int> under_roots;
  std::map<int, std::vector<Vec3>> root_ties;
  for (std::size_t n = 0; n < net.nodes.size(); ++n) {
    if (!node_has_member[n] || node_tied[n] == 0) continue;
    root_ties[comp.find(static_cast<int>(n))].push_back(net.nodes[n]);
  }
  // a component with a WELDED tie is fully restrained by that one joint
  std::set<int> welded_roots;
  if (node_welded)
    for (std::size_t n = 0; n < net.nodes.size(); ++n)
      if (node_has_member[n] && (*node_welded)[n])
        welded_roots.insert(comp.find(static_cast<int>(n)));
  for (const auto& kv : root_has_tie) {
    if (!kv.second) continue;                   // already counted as untied
    if (welded_roots.count(kv.first)) continue; // one moment tie is enough
    const auto it = root_ties.find(kv.first);
    const std::vector<Vec3>& pts2 =
        (it == root_ties.end()) ? std::vector<Vec3>() : it->second;
    bool ok = false;
    if (pts2.size() >= 3) {
      // non-collinear if some pair of edge vectors from pts2[0] has a non-zero cross
      double best = 0.0, scale = 0.0;
      for (std::size_t a = 1; a < pts2.size(); ++a) {
        const double ux = pts2[a].x - pts2[0].x, uy = pts2[a].y - pts2[0].y,
                     uz = pts2[a].z - pts2[0].z;
        scale = std::max(scale, std::sqrt(ux * ux + uy * uy + uz * uz));
        for (std::size_t b2 = a + 1; b2 < pts2.size(); ++b2) {
          const double vx = pts2[b2].x - pts2[0].x, vy = pts2[b2].y - pts2[0].y,
                       vz = pts2[b2].z - pts2[0].z;
          const double cx = uy * vz - uz * vy, cy = uz * vx - ux * vz,
                       cz = ux * vy - uy * vx;
          best = std::max(best, std::sqrt(cx * cx + cy * cy + cz * cz));
        }
      }
      ok = (scale > 0.0) && (best > 1e-9 * scale * scale);
    }
    if (!ok) {
      ++rep.components_underconstrained;
      under_roots.insert(kv.first);
    }
  }
  for (std::size_t i = 0; i < net.members.size(); ++i)
    if (under_roots.count(comp.find(net.members[i].node_a)))
      rep.member_underconstrained[i] = 1;
  return rep;
}

BeamSection beam_section_circular(double radius_mm) {
  if (!(radius_mm > 0.0))
    throw std::invalid_argument("beam_section_circular: radius must be > 0");
  const double r2 = radius_mm * radius_mm;
  BeamSection s;
  s.area = M_PI * r2;
  s.inertia = M_PI * r2 * r2 / 4.0;
  s.torsion_j = 2.0 * s.inertia;
  return s;
}



// ── ★ A WALL AS A SHELL MESH ────────────────────────────────────────────────
namespace {

// Even-odd point-in-polygon on a set of loops: loop 0 is the outline, the rest are
// holes, so an odd crossing count means inside.
bool inside_loops(double u, double w,
                  const std::vector<std::vector<std::array<double, 2>>>& loops) {
  bool in = false;
  for (const auto& loop : loops) {
    const std::size_t n = loop.size();
    for (std::size_t i = 0, j = n - 1; i < n; j = i++) {
      const double ui = loop[i][0], wi = loop[i][1];
      const double uj = loop[j][0], wj = loop[j][1];
      if (((wi > w) != (wj > w)) &&
          (u < (uj - ui) * (w - wi) / (wj - wi) + ui))
        in = !in;
    }
  }
  return in;
}

}  // namespace

ShellMesh mesh_face_region_midsurface(
    const Vec3& origin, const Vec3& normal, double half_u, double half_w,
    double thickness_mm, const std::vector<std::vector<std::array<double, 2>>>& loops,
    double target_edge_mm) {
  if (!(half_u > 0.0) || !(half_w > 0.0))
    throw std::invalid_argument("mesh_face_region_midsurface: extents must be > 0");
  if (!(thickness_mm > 0.0))
    throw std::invalid_argument("mesh_face_region_midsurface: thickness must be > 0");
  if (!(target_edge_mm > 0.0))
    throw std::invalid_argument("mesh_face_region_midsurface: edge length must be > 0");
  const double nl = std::sqrt(normal.x*normal.x + normal.y*normal.y + normal.z*normal.z);
  if (!(nl > 0.0))
    throw std::invalid_argument("mesh_face_region_midsurface: zero normal");

  ShellMesh m;
  m.thickness_mm = thickness_mm;
  m.normal = Vec3{normal.x/nl, normal.y/nl, normal.z/nl};
  // the SAME plane basis the region declaration uses, so (u, w) here means what it
  // means there -- a different basis would silently rotate every loop
  {
    const Vec3 ref = std::fabs(m.normal.x) < 0.9 ? Vec3{1,0,0} : Vec3{0,1,0};
    const Vec3 uu{ref.y*m.normal.z - ref.z*m.normal.y,
                  ref.z*m.normal.x - ref.x*m.normal.z,
                  ref.x*m.normal.y - ref.y*m.normal.x};
    const double ul = std::sqrt(uu.x*uu.x + uu.y*uu.y + uu.z*uu.z);
    if (!(ul > 1e-12))
      throw std::invalid_argument("mesh_face_region_midsurface: degenerate basis");
    m.basis_u = Vec3{uu.x/ul, uu.y/ul, uu.z/ul};
    m.basis_w = Vec3{m.normal.y*m.basis_u.z - m.normal.z*m.basis_u.y,
                     m.normal.z*m.basis_u.x - m.normal.x*m.basis_u.z,
                     m.normal.x*m.basis_u.y - m.normal.y*m.basis_u.x};
  }
  // the mid-surface sits HALF A THICKNESS in from the declared face
  const double off = 0.5 * thickness_mm;
  const Vec3 base{origin.x + m.normal.x*off, origin.y + m.normal.y*off,
                  origin.z + m.normal.z*off};

  const int nu = std::max(1, static_cast<int>(std::ceil(2.0*half_u/target_edge_mm)));
  const int nw = std::max(1, static_cast<int>(std::ceil(2.0*half_w/target_edge_mm)));
  const double du = 2.0*half_u/nu, dw = 2.0*half_w/nw;

  std::vector<int> id(static_cast<std::size_t>(nu+1)*(nw+1), -1);
  for (int j = 0; j <= nw; ++j)
    for (int i = 0; i <= nu; ++i) {
      const double u = -half_u + i*du, w = -half_w + j*dw;
      if (!loops.empty() && !inside_loops(u, w, loops)) continue;
      id[static_cast<std::size_t>(j)*(nu+1) + i] = static_cast<int>(m.nodes.size());
      m.local_u.push_back(u);
      m.local_w.push_back(w);
      m.nodes.push_back(Vec3{base.x + m.basis_u.x*u + m.basis_w.x*w,
                             base.y + m.basis_u.y*u + m.basis_w.y*w,
                             base.z + m.basis_u.z*u + m.basis_w.z*w});
    }
  // two triangles per cell, but only where all four corners survived the outline
  for (int j = 0; j < nw; ++j)
    for (int i = 0; i < nu; ++i) {
      const int a = id[static_cast<std::size_t>(j)*(nu+1) + i];
      const int b = id[static_cast<std::size_t>(j)*(nu+1) + i+1];
      const int c = id[static_cast<std::size_t>(j+1)*(nu+1) + i+1];
      const int d = id[static_cast<std::size_t>(j+1)*(nu+1) + i];
      if (a < 0 || b < 0 || c < 0 || d < 0) continue;
      m.triangles.push_back({a, b, c});
      m.triangles.push_back({a, c, d});
    }
  return m;
}

// ── ★ THE COUPLED SOLVE ─────────────────────────────────────────────────────
namespace {

// Sparse symmetric matrix built by scatter, then compressed. Dependency-free
// (ARCHITECTURE §4): triplets -> CSR -> Jacobi-preconditioned CG.
struct Sparse {
  std::vector<int> row, col;
  std::vector<double> val;
  void add(int r, int c, double v) {
    if (v == 0.0) return;
    row.push_back(r); col.push_back(c); val.push_back(v);
  }
};

struct Csr {
  std::vector<int> ptr, idx;
  std::vector<double> val;
  int n = 0;
  std::size_t nnz() const { return val.size(); }
  void multiply(const std::vector<double>& x, std::vector<double>& y) const {
    for (int i = 0; i < n; ++i) {
      double acc = 0.0;
      for (int k = ptr[static_cast<std::size_t>(i)];
           k < ptr[static_cast<std::size_t>(i) + 1]; ++k)
        acc += val[static_cast<std::size_t>(k)] *
               x[static_cast<std::size_t>(idx[static_cast<std::size_t>(k)])];
      y[static_cast<std::size_t>(i)] = acc;
    }
  }
};

// Sums duplicate (i, j) entries and sorts each row. Assembly emits many triplets per
// entry; leaving them separate makes every downstream pass walk more memory than it
// needs, and any routine that looks for "the diagonal entry" finds several. A
// Gauss-Seidel sweep needs the row ordered to split L from U, so this is not an
// optimisation but a correctness requirement for the preconditioner below.
Csr compress(const Sparse& s, int n) {
  Csr m;
  m.n = n;
  m.ptr.assign(static_cast<std::size_t>(n) + 1, 0);
  for (int r : s.row) ++m.ptr[static_cast<std::size_t>(r) + 1];
  for (int i = 0; i < n; ++i)
    m.ptr[static_cast<std::size_t>(i) + 1] += m.ptr[static_cast<std::size_t>(i)];
  std::vector<int> cursor(m.ptr.begin(), m.ptr.end() - 1);
  m.idx.assign(s.val.size(), 0);
  m.val.assign(s.val.size(), 0.0);
  for (std::size_t k = 0; k < s.val.size(); ++k) {
    const int r = s.row[k];
    const int at = cursor[static_cast<std::size_t>(r)]++;
    m.idx[static_cast<std::size_t>(at)] = s.col[k];
    m.val[static_cast<std::size_t>(at)] = s.val[k];
  }
  // sort each row by column and fold duplicates together
  Csr out2;
  out2.n = n;
  out2.ptr.assign(static_cast<std::size_t>(n) + 1, 0);
  out2.idx.reserve(m.idx.size());
  out2.val.reserve(m.val.size());
  std::vector<std::pair<int, double>> row;
  for (int i = 0; i < n; ++i) {
    row.clear();
    for (int k = m.ptr[static_cast<std::size_t>(i)];
         k < m.ptr[static_cast<std::size_t>(i) + 1]; ++k)
      row.emplace_back(m.idx[static_cast<std::size_t>(k)], m.val[static_cast<std::size_t>(k)]);
    std::sort(row.begin(), row.end(),
              [](const std::pair<int,double>& a, const std::pair<int,double>& b) {
                return a.first < b.first; });
    for (std::size_t k = 0; k < row.size();) {
      std::size_t j = k;
      double acc = 0.0;
      while (j < row.size() && row[j].first == row[k].first) acc += row[j++].second;
      if (acc != 0.0) { out2.idx.push_back(row[k].first); out2.val.push_back(acc); }
      k = j;
    }
    out2.ptr[static_cast<std::size_t>(i) + 1] = static_cast<int>(out2.idx.size());
  }
  return out2;
}

}  // namespace


namespace {

// ── ★ SYMMETRIC GAUSS-SEIDEL PRECONDITIONER ─────────────────────────────────
// Jacobi divides by the diagonal and nothing else. On a system that mixes hex
// (stiffness ~ E*h, thousands), shell membrane (very stiff), shell bending (very
// soft) and beam bending (EI/L^3 with I ~ 0.05 mm^4), the off-diagonal coupling
// between those scales is exactly what has to be captured, and Jacobi captures none
// of it. MEASURED with Jacobi on a real part: residual parked at 2.0 after 20,500
// iterations, on a system that is symmetric, positive semi-definite and fully
// connected -- so nothing was wrong except the preconditioner.
//
// SGS applies (D+L) D^-1 (D+U), i.e. a forward sweep and a backward sweep. It costs
// two triangular solves per iteration -- the same shape as IC(0) but with NO
// factorisation, so it cannot break down and needs no shift ladder. It is also the
// standard smoother inside the block preconditioners the mixed-dimensional
// beam-solid literature builds, so it is the honest first rung of that ladder rather
// than a detour around it.
struct SymGaussSeidel {
  const Csr* A = nullptr;
  std::vector<double> diag;
  std::vector<int> dpos;                    // index of the diagonal entry per row

  void build(const Csr& a) {
    A = &a;
    diag.assign(static_cast<std::size_t>(a.n), 0.0);
    for (int i = 0; i < a.n; ++i)
      for (int k = a.ptr[static_cast<std::size_t>(i)];
           k < a.ptr[static_cast<std::size_t>(i) + 1]; ++k)
        if (a.idx[static_cast<std::size_t>(k)] == i)
          diag[static_cast<std::size_t>(i)] += a.val[static_cast<std::size_t>(k)];
    for (double& d : diag) if (!(d > 0.0)) d = 1.0;
  }

  // z = M^-1 r  with  M = (D+L) D^-1 (D+U)
  void apply(const std::vector<double>& r, std::vector<double>& z) const {
    const Csr& a = *A;
    const int n = a.n;
    z.assign(static_cast<std::size_t>(n), 0.0);
    for (int i = 0; i < n; ++i) {              // forward: (D+L) y = r
      double acc = r[static_cast<std::size_t>(i)];
      for (int k = a.ptr[static_cast<std::size_t>(i)];
           k < a.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = a.idx[static_cast<std::size_t>(k)];
        if (j < i) acc -= a.val[static_cast<std::size_t>(k)] * z[static_cast<std::size_t>(j)];
      }
      z[static_cast<std::size_t>(i)] = acc / diag[static_cast<std::size_t>(i)];
    }
    for (int i = 0; i < n; ++i)                // scale by D
      z[static_cast<std::size_t>(i)] *= diag[static_cast<std::size_t>(i)];
    for (int i = n - 1; i >= 0; --i) {         // backward: (D+U) z = y
      double acc = z[static_cast<std::size_t>(i)];
      for (int k = a.ptr[static_cast<std::size_t>(i)];
           k < a.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = a.idx[static_cast<std::size_t>(k)];
        if (j > i) acc -= a.val[static_cast<std::size_t>(k)] * z[static_cast<std::size_t>(j)];
      }
      z[static_cast<std::size_t>(i)] = acc / diag[static_cast<std::size_t>(i)];
    }
  }
};

// ── ★ REVERSE CUTHILL-McKEE ─────────────────────────────────────────────────
// The coupled system numbers all the SOLID dof first and all the BEAM dof after,
// so every tie scatters its coupling far off the diagonal. RCM renumbers by
// breadth-first distance from a peripheral node, which pulls those entries in.
// A narrow band is what makes an incomplete factorisation a good approximation:
// IC(0) keeps only the sparsity of A, so the further the true fill-in lies from
// that pattern, the more of it is thrown away.
std::vector<int> rcm_order(const Csr& A) {
  const int n = A.n;
  std::vector<int> deg(static_cast<std::size_t>(n));
  for (int i = 0; i < n; ++i)
    deg[static_cast<std::size_t>(i)] =
        A.ptr[static_cast<std::size_t>(i) + 1] - A.ptr[static_cast<std::size_t>(i)];
  std::vector<char> seen(static_cast<std::size_t>(n), 0);
  std::vector<int> order;
  order.reserve(static_cast<std::size_t>(n));
  for (int start = 0; start < n; ++start) {
    if (seen[static_cast<std::size_t>(start)]) continue;
    // a low-degree seed approximates a peripheral node cheaply
    int seed = start;
    for (int i = start; i < n; ++i)
      if (!seen[static_cast<std::size_t>(i)] &&
          deg[static_cast<std::size_t>(i)] < deg[static_cast<std::size_t>(seed)])
        seed = i;
    std::vector<int> queue{seed};
    seen[static_cast<std::size_t>(seed)] = 1;
    for (std::size_t qi = 0; qi < queue.size(); ++qi) {
      const int v = queue[qi];
      order.push_back(v);
      std::vector<int> nbr;
      for (int k = A.ptr[static_cast<std::size_t>(v)];
           k < A.ptr[static_cast<std::size_t>(v) + 1]; ++k) {
        const int w = A.idx[static_cast<std::size_t>(k)];
        if (w != v && !seen[static_cast<std::size_t>(w)]) {
          seen[static_cast<std::size_t>(w)] = 1;
          nbr.push_back(w);
        }
      }
      std::sort(nbr.begin(), nbr.end(), [&](int a, int b) {
        return deg[static_cast<std::size_t>(a)] < deg[static_cast<std::size_t>(b)];
      });
      for (int w : nbr) queue.push_back(w);
    }
  }
  std::reverse(order.begin(), order.end());   // the R in RCM
  return order;
}

// ── ★ INCOMPLETE CHOLESKY, IC(0) ────────────────────────────────────────────
// A ~ L L^T keeping ONLY the sparsity of A's lower triangle. Symmetric, so it
// preserves the property CG needs; ILU does not. IC(0) can break down on an
// ill-conditioned matrix (a non-positive pivot), and the standard remedy is a
// diagonal shift, retried with a growing shift until it succeeds. Returns false
// if even a large shift fails, so the caller can fall back to Jacobi rather than
// silently using a broken preconditioner.
struct IncompleteCholesky {
  std::vector<int> ptr, idx;
  std::vector<double> val;   // lower triangle including the diagonal
  int n = 0;

  bool factor(const Csr& A, double shift) {
    n = A.n;
    ptr.assign(static_cast<std::size_t>(n) + 1, 0);
    idx.clear();
    val.clear();
    // lower-triangle pattern of A
    for (int i = 0; i < n; ++i) {
      for (int k = A.ptr[static_cast<std::size_t>(i)];
           k < A.ptr[static_cast<std::size_t>(i) + 1]; ++k)
        if (A.idx[static_cast<std::size_t>(k)] <= i) {
          idx.push_back(A.idx[static_cast<std::size_t>(k)]);
          val.push_back(A.val[static_cast<std::size_t>(k)]);
        }
      ptr[static_cast<std::size_t>(i) + 1] = static_cast<int>(idx.size());
    }
    for (int i = 0; i < n; ++i)
      for (int k = ptr[static_cast<std::size_t>(i)];
           k < ptr[static_cast<std::size_t>(i) + 1]; ++k)
        if (idx[static_cast<std::size_t>(k)] == i)
          val[static_cast<std::size_t>(k)] *= (1.0 + shift);

    std::vector<double> work(static_cast<std::size_t>(n), 0.0);
    std::vector<int> pos(static_cast<std::size_t>(n), -1);
    for (int i = 0; i < n; ++i) {
      for (int k = ptr[static_cast<std::size_t>(i)];
           k < ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        work[static_cast<std::size_t>(idx[static_cast<std::size_t>(k)])] =
            val[static_cast<std::size_t>(k)];
        pos[static_cast<std::size_t>(idx[static_cast<std::size_t>(k)])] = k;
      }
      for (int k = ptr[static_cast<std::size_t>(i)];
           k < ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = idx[static_cast<std::size_t>(k)];
        if (j >= i) continue;
        double s = work[static_cast<std::size_t>(j)];
        for (int m = ptr[static_cast<std::size_t>(j)];
             m < ptr[static_cast<std::size_t>(j) + 1]; ++m) {
          const int c = idx[static_cast<std::size_t>(m)];
          if (c >= j) break;
          if (pos[static_cast<std::size_t>(c)] >= 0)
            s -= val[static_cast<std::size_t>(m)] *
                 val[static_cast<std::size_t>(pos[static_cast<std::size_t>(c)])];
        }
        double djj = 0.0;
        for (int m = ptr[static_cast<std::size_t>(j)];
             m < ptr[static_cast<std::size_t>(j) + 1]; ++m)
          if (idx[static_cast<std::size_t>(m)] == j) djj = val[static_cast<std::size_t>(m)];
        if (!(std::fabs(djj) > 0.0)) return false;
        val[static_cast<std::size_t>(k)] = s / djj;
        work[static_cast<std::size_t>(j)] = val[static_cast<std::size_t>(k)];
      }
      // the diagonal
      int dk = -1;
      double d = 0.0;
      for (int k = ptr[static_cast<std::size_t>(i)];
           k < ptr[static_cast<std::size_t>(i) + 1]; ++k)
        if (idx[static_cast<std::size_t>(k)] == i) { dk = k; d = work[static_cast<std::size_t>(i)]; }
      if (dk < 0) return false;
      for (int k = ptr[static_cast<std::size_t>(i)];
           k < ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = idx[static_cast<std::size_t>(k)];
        if (j < i) d -= val[static_cast<std::size_t>(k)] * val[static_cast<std::size_t>(k)];
      }
      if (!(d > 0.0)) return false;                    // breakdown: caller shifts
      val[static_cast<std::size_t>(dk)] = std::sqrt(d);
      for (int k = ptr[static_cast<std::size_t>(i)];
           k < ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        pos[static_cast<std::size_t>(idx[static_cast<std::size_t>(k)])] = -1;
        work[static_cast<std::size_t>(idx[static_cast<std::size_t>(k)])] = 0.0;
      }
    }
    return true;
  }

  // z = (L L^T)^-1 r
  void apply(const std::vector<double>& r, std::vector<double>& z) const {
    z = r;
    for (int i = 0; i < n; ++i) {              // forward
      double s = z[static_cast<std::size_t>(i)];
      double d = 1.0;
      for (int k = ptr[static_cast<std::size_t>(i)];
           k < ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = idx[static_cast<std::size_t>(k)];
        if (j < i) s -= val[static_cast<std::size_t>(k)] * z[static_cast<std::size_t>(j)];
        else if (j == i) d = val[static_cast<std::size_t>(k)];
      }
      z[static_cast<std::size_t>(i)] = s / d;
    }
    for (int i = n - 1; i >= 0; --i) {         // backward
      double d = 1.0;
      for (int k = ptr[static_cast<std::size_t>(i)];
           k < ptr[static_cast<std::size_t>(i) + 1]; ++k)
        if (idx[static_cast<std::size_t>(k)] == i) d = val[static_cast<std::size_t>(k)];
      z[static_cast<std::size_t>(i)] /= d;
      for (int k = ptr[static_cast<std::size_t>(i)];
           k < ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = idx[static_cast<std::size_t>(k)];
        if (j < i) z[static_cast<std::size_t>(j)] -= val[static_cast<std::size_t>(k)] *
                                                     z[static_cast<std::size_t>(i)];
      }
    }
  }
};

}  // namespace

CoupledLatticeSolve solve_coupled_lattice(
    const VoxelGrid& grid, const std::vector<char>& hex_mask,
    const BeamNetwork& net, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, double youngs_modulus, double poisson,
    double shear_k, double cg_tolerance, int cg_max_iterations,
    const std::vector<double>* hex_solid_fraction,
    const std::vector<ShellPatch>* shells, const CgProgress* progress,
    const SolveStage* stage) {
  CoupledLatticeSolve out;
  auto stage_t0 = std::chrono::steady_clock::now();
  auto mark = [&](const char* name, double size) {
    const auto now = std::chrono::steady_clock::now();
    if (stage && stage->fn)
      stage->fn(name, std::chrono::duration<double>(now - stage_t0).count(), size,
                stage->user);
    stage_t0 = now;
  };
  if (hex_solid_fraction && hex_solid_fraction->size() != grid.voxel_count()) {
    out.refusal = "hex_solid_fraction size does not match the grid";
    return out;
  }
  if (hex_mask.size() != grid.voxel_count()) {
    out.refusal = "hex_mask size does not match the grid";
    return out;
  }
  if (!(youngs_modulus > 0.0) || !(poisson > -1.0 && poisson < 0.5)) {
    out.refusal = "non-physical material";
    return out;
  }

  const int NX = grid.nx + 1, NY = grid.ny + 1;
  auto node_index = [&](int i, int j, int k) {
    return (static_cast<std::size_t>(k) * NY + j) * NX + i;
  };

  // ── number the solid nodes a meshed voxel touches ────────────────────────
  std::vector<int> nid(static_cast<std::size_t>(NX) * NY * (grid.nz + 1), -1);
  std::vector<std::size_t> hex_cells;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!hex_mask[e]) continue;
        hex_cells.push_back(e);
        for (int dk = 0; dk < 2; ++dk)
          for (int dj = 0; dj < 2; ++dj)
            for (int di = 0; di < 2; ++di) nid[node_index(i + di, j + dj, k + dk)] = 0;
      }
  int NS = 0;
  for (std::size_t n = 0; n < nid.size(); ++n)
    if (nid[n] == 0) nid[n] = NS++;
  if (NS == 0) {
    out.refusal = "hex_mask meshes no solid";
    return out;
  }

  mark("solid nodes numbered", static_cast<double>(NS));
  // ── ★ SHELL NODES, numbered after the solid ones ──────────────────────────
  // Each patch keeps its own node block; nothing merges patches, so a caller can
  // hand in the two faces of a prism without them silently sharing an edge.
  std::vector<int> shell_base;
  int NSH = 0;
  if (shells)
    for (const ShellPatch& sp2 : *shells) {
      shell_base.push_back(NSH);
      NSH += static_cast<int>(sp2.mesh.nodes.size());
      out.shell_nodes += sp2.mesh.nodes.size();
      out.shell_triangles += sp2.mesh.triangles.size();
    }

  // ── ★ TIE THE SKIN INTO THE SOLID ─────────────────────────────────────────
  // The grade-to-solid skin FUSES to the wall around it -- that is what grading to
  // solid means -- so its nodes must be bonded to the hex mesh. Leaving this out
  // makes the whole shell+lattice assembly a free-floating body: zero-energy rigid
  // modes, an indefinite matrix, and CG that DIVERGES rather than converging slowly
  // (measured: residual climbing 1.00 -> 1.35 -> 1.62 over 1,500 iterations).
  //
  // TRANSLATIONS ONLY. A hex node has no rotational dof to receive a moment, so this
  // joint is necessarily pinned -- unlike the beam-to-shell weld. That is adequate
  // here because a plate tied at MANY points along its edge is fully restrained
  // without moment at any one of them; it is the single-point case that needs a
  // moment path.
  std::vector<char> shell_tied(static_cast<std::size_t>(NSH), 0);
  std::vector<std::array<int, 8>> shell_host(static_cast<std::size_t>(NSH));
  std::vector<FrameSolidTie> shell_w(static_cast<std::size_t>(NSH));
  if (NSH > 0) {
    for (std::size_t pidx = 0; pidx < shells->size(); ++pidx) {
      const ShellMesh& sm2 = (*shells)[pidx].mesh;
      for (std::size_t n = 0; n < sm2.nodes.size(); ++n) {
        const Vec3& q = sm2.nodes[n];
        const int i = static_cast<int>(std::floor((q.x - grid.origin.x) / grid.spacing));
        const int j = static_cast<int>(std::floor((q.y - grid.origin.y) / grid.spacing));
        const int k = static_cast<int>(std::floor((q.z - grid.origin.z) / grid.spacing));
        int hi = -1, hj = -1, hk = -1;
        double best = -1.0;
        for (int dk = -1; dk <= 1; ++dk)
          for (int dj = -1; dj <= 1; ++dj)
            for (int di = -1; di <= 1; ++di) {
              const int ci = i + di, cj = j + dj, ck = k + dk;
              if (ci < 0 || cj < 0 || ck < 0 || ci >= grid.nx || cj >= grid.ny ||
                  ck >= grid.nz) continue;
              if (!hex_mask[grid.index(ci, cj, ck)]) continue;
              const double cx = grid.origin.x + (ci + 0.5) * grid.spacing;
              const double cy = grid.origin.y + (cj + 0.5) * grid.spacing;
              const double cz = grid.origin.z + (ck + 0.5) * grid.spacing;
              const double d2 = (q.x-cx)*(q.x-cx) + (q.y-cy)*(q.y-cy) + (q.z-cz)*(q.z-cz);
              if (best < 0.0 || d2 < best) { best = d2; hi = ci; hj = cj; hk = ck; }
            }
        if (hi < 0) continue;                       // no solid nearby: interior skin
        const Vec3 org2{grid.origin.x + hi * grid.spacing,
                        grid.origin.y + hj * grid.spacing,
                        grid.origin.z + hk * grid.spacing};
        const int sid = shell_base[pidx] + static_cast<int>(n);
        shell_w[static_cast<std::size_t>(sid)] = frame_solid_tie(q, org2, grid.spacing);
        {
          double sum = 0.0;
          for (double& wv : shell_w[static_cast<std::size_t>(sid)].weight) {
            wv = std::max(0.0, wv); sum += wv;
          }
          if (sum > 0.0)
            for (double& wv : shell_w[static_cast<std::size_t>(sid)].weight) wv /= sum;
        }
        int raw[8], nn = 0; bool ok = true;
        for (int dk = 0; dk < 2 && ok; ++dk)
          for (int dj = 0; dj < 2 && ok; ++dj)
            for (int di = 0; di < 2 && ok; ++di) {
              const int id = nid[node_index(hi + di, hj + dj, hk + dk)];
              if (id < 0) ok = false;
              raw[nn++] = id;
            }
        if (!ok) continue;
        const int ccw[8] = {0, 1, 3, 2, 4, 5, 7, 6};
        FrameSolidTie rem = shell_w[static_cast<std::size_t>(sid)];
        for (int a = 0; a < 8; ++a) {
          shell_host[static_cast<std::size_t>(sid)][static_cast<std::size_t>(a)] = raw[ccw[a]];
          rem.weight[static_cast<std::size_t>(a)] =
              shell_w[static_cast<std::size_t>(sid)].weight[static_cast<std::size_t>(ccw[a])];
        }
        shell_w[static_cast<std::size_t>(sid)] = rem;
        shell_tied[static_cast<std::size_t>(sid)] = 1;
        ++out.shell_nodes_tied;
      }
    }
    // ★ EVERY ELEMENT FAMILY MUST REACH GROUND, not just the lattice. A patch bonded
    // nowhere is a free body however well the beams hanging off it are restrained.
    for (std::size_t pidx = 0; pidx < shells->size(); ++pidx) {
      const int b0 = shell_base[pidx];
      const int b1 = b0 + static_cast<int>((*shells)[pidx].mesh.nodes.size());
      std::size_t n_tied = 0;
      for (int n = b0; n < b1; ++n) n_tied += shell_tied[static_cast<std::size_t>(n)] ? 1u : 0u;
      if (n_tied < 3) {
        out.refusal = "shell patch " + std::to_string(pidx) + " is bonded to the solid at " +
                      std::to_string(n_tied) +
                      " node(s): fewer than three leaves it a free-floating body and the "
                      "system is indefinite. Check that the skin overlaps meshed solid.";
        return out;
      }
    }
  }

  // ── tie every beam node that lands in a meshed voxel ──────────────────────
  const std::size_t NB = net.node_count();
  std::vector<char> tied(NB, 0), welded(NB, 0);
  std::vector<int> weld_to(NB, -1);
  // ── ★ WELD TO THE SKIN FIRST. The lattice attaches at the grade-to-solid
  // boundary, and that boundary is a SHELL -- so the joint can carry moment. Only
  // beam nodes that find no shell node fall back to the pinned hex tie.
  if (shells) {
    double reach = 0.0;
    for (const ShellPatch& sp2 : *shells)
      for (const ShellMesh::Tri& t2 : sp2.mesh.triangles) {
        const Vec3& a2 = sp2.mesh.nodes[static_cast<std::size_t>(t2.a)];
        const Vec3& b2 = sp2.mesh.nodes[static_cast<std::size_t>(t2.b)];
        const double dx = a2.x-b2.x, dy = a2.y-b2.y, dz = a2.z-b2.z;
        reach = std::max(reach, std::sqrt(dx*dx+dy*dy+dz*dz));
      }
    reach *= 0.75;
    for (std::size_t b = 0; b < NB; ++b) {
      double best = reach; int hit = -1;
      for (std::size_t pidx = 0; pidx < shells->size(); ++pidx) {
        const ShellMesh& sm2 = (*shells)[pidx].mesh;
        for (std::size_t n = 0; n < sm2.nodes.size(); ++n) {
          const double dx = net.nodes[b].x - sm2.nodes[n].x;
          const double dy = net.nodes[b].y - sm2.nodes[n].y;
          const double dz = net.nodes[b].z - sm2.nodes[n].z;
          const double d = std::sqrt(dx*dx+dy*dy+dz*dz);
          if (d < best) { best = d; hit = shell_base[pidx] + static_cast<int>(n); }
        }
      }
      if (hit >= 0) {
        weld_to[b] = hit; welded[b] = 1; tied[b] = 1;
        ++out.beam_nodes_welded_to_shell; ++out.beam_nodes_tied;
      }
    }
  }
  std::vector<std::array<int, 8>> tie_node(NB);
  std::vector<FrameSolidTie> tie_w(NB);
  for (std::size_t b = 0; b < NB; ++b) {
    if (welded[b]) continue;                 // already joined to the skin
    const Vec3& p = net.nodes[b];
    const int i = static_cast<int>(std::floor((p.x - grid.origin.x) / grid.spacing));
    const int j = static_cast<int>(std::floor((p.y - grid.origin.y) / grid.spacing));
    const int k = static_cast<int>(std::floor((p.z - grid.origin.z) / grid.spacing));
    // ★ TIE AT THE INTERFACE, not only strictly inside a meshed voxel. The lattice
    // occupies a region that by construction has NO hex elements, so "inside a hex"
    // ties almost nothing: measured 166 of 22,252 nodes on a real part, leaving the
    // lattice hanging off 166 points. A strut is bonded wherever it TOUCHES solid,
    // so search the 3x3x3 neighbourhood for a meshed voxel and clamp onto it.
    int hi = -1, hj = -1, hk = -1;
    {
      double best = -1.0;
      for (int dk = -1; dk <= 1; ++dk)
        for (int dj = -1; dj <= 1; ++dj)
          for (int di = -1; di <= 1; ++di) {
            const int ci = i + di, cj = j + dj, ck = k + dk;
            if (ci < 0 || cj < 0 || ck < 0 || ci >= grid.nx || cj >= grid.ny ||
                ck >= grid.nz)
              continue;
            if (!hex_mask[grid.index(ci, cj, ck)]) continue;
            const double cx = grid.origin.x + (ci + 0.5) * grid.spacing;
            const double cy = grid.origin.y + (cj + 0.5) * grid.spacing;
            const double cz = grid.origin.z + (ck + 0.5) * grid.spacing;
            const double d2 = (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy) +
                              (p.z - cz) * (p.z - cz);
            if (best < 0.0 || d2 < best) { best = d2; hi = ci; hj = cj; hk = ck; }
          }
    }
    if (hi < 0) continue;
    const int i_h = hi, j_h = hj, k_h = hk;
    const Vec3 org{grid.origin.x + i_h * grid.spacing,
                   grid.origin.y + j_h * grid.spacing,
                   grid.origin.z + k_h * grid.spacing};
    tie_w[b] = frame_solid_tie(p, org, grid.spacing);
    // clamp the local coordinates: a node just OUTSIDE its host must tie to the
    // nearest face, never extrapolate (which would invent stiffness).
    {
      double sum = 0.0;
      for (double& w : tie_w[b].weight) { w = std::max(0.0, w); sum += w; }
      if (sum > 0.0) for (double& w : tie_w[b].weight) w /= sum;
    }
    // frame_solid_tie returns weights in x-fastest order; remap BOTH the weights
    // and the node ids into core's bottom-CCW-then-top-CCW order so a tie lands on
    // the same corner the element stiffness used.
    int raw_ids[8];
    int n = 0;
    bool ok = true;
    for (int dk = 0; dk < 2 && ok; ++dk)
      for (int dj = 0; dj < 2 && ok; ++dj)
        for (int di = 0; di < 2 && ok; ++di) {
          const int id = nid[node_index(i_h + di, j_h + dj, k_h + dk)];
          if (id < 0) ok = false;
          raw_ids[n++] = id;
        }
    {
      const int ccw[8] = {0, 1, 3, 2, 4, 5, 7, 6};
      FrameSolidTie remapped = tie_w[b];
      for (int a = 0; a < 8; ++a) {
        tie_node[b][static_cast<std::size_t>(a)] = raw_ids[ccw[a]];
        remapped.weight[static_cast<std::size_t>(a)] =
            tie_w[b].weight[static_cast<std::size_t>(ccw[a])];
      }
      tie_w[b] = remapped;
    }
    if (ok) { tied[b] = 1; ++out.beam_nodes_tied;
              if (!tie_w[b].inside) ++out.beam_nodes_tied_by_projection; }
  }

  mark("beam-to-solid ties", static_cast<double>(out.beam_nodes_tied));
  // ── ★ RESTRAINT BEFORE FACTORISATION, not after it fails ─────────────────
  out.restraint = beam_network_restraint(net, tied, &welded);
  if (out.restraint.components_unrestrained > 0) {
    out.refusal =
        std::to_string(out.restraint.components_unrestrained) + " of " +
        std::to_string(out.restraint.components_total) +
        " lattice component(s) reach no tie at all: they carry no load and make the "
        "system singular. Drop them, or widen the tie, before solving.";
    return out;
  }
  if (out.restraint.components_underconstrained > 0) {
    out.refusal =
        std::to_string(out.restraint.components_underconstrained) + " of " +
        std::to_string(out.restraint.components_total) +
        " lattice component(s) are held at fewer than three NON-COLLINEAR tie "
        "points: a pinned tie restrains translation only, so they can still rotate "
        "rigidly and the system is singular.";
    return out;
  }
  if (out.restraint.members_unrestrained > 0) {
    out.refusal = "the network contains " +
                  std::to_string(out.restraint.members_unrestrained) +
                  " unrestrained member(s): a pinned tie leaves them free to rotate, "
                  "so the system would be singular. Drop or restrain them first.";
    return out;
  }

  mark("restraint analysis", static_cast<double>(out.restraint.components_total));
  // ── ★ THE SOLID MUST REACH A SUPPORT TOO ──────────────────────────────────
  // Every restraint rule above is about the LATTICE. None of them notices that the
  // part itself can contain hex islands with no path to a Dirichlet node -- rigid
  // bodies that make the system singular however perfectly the lattice is tied. The
  // STL is one body only after the lattice is added; the solid alone need not be.
  {
    DisjointSet sc(static_cast<std::size_t>(NS));
    for (std::size_t e : hex_cells) {
      const int i = static_cast<int>(e % grid.nx);
      const int j = static_cast<int>((e / grid.nx) % grid.ny);
      const int k = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) * grid.ny));
      int first = -1;
      for (int dk = 0; dk < 2; ++dk)
        for (int dj = 0; dj < 2; ++dj)
          for (int di = 0; di < 2; ++di) {
            const int id = nid[node_index(i + di, j + dj, k + dk)];
            if (first < 0) first = id; else sc.unite(first, id);
          }
    }
    std::set<int> grounded;
    for (const DirichletBC& b : bcs) {
      if (b.node < 0 || static_cast<std::size_t>(b.node) >= nid.size()) continue;
      const int n = nid[static_cast<std::size_t>(b.node)];
      if (n >= 0) grounded.insert(sc.find(n));
    }
    std::size_t floating = 0;
    for (int n = 0; n < NS; ++n)
      if (!grounded.count(sc.find(n))) ++floating;
    if (floating > 0) {
      out.refusal = std::to_string(floating) + " of " + std::to_string(NS) +
                    " SOLID nodes reach no support: the part contains free-floating "
                    "hex island(s), so the system is singular regardless of how the "
                    "lattice is tied.";
      return out;
    }
  }

  mark("solid connectivity", static_cast<double>(NS));
  // ── master DOF: [3*NS solid][the beam dof that are NOT slaved] ────────────
  const int SB = 3 * NS;                 // solid dof: 3 per node
  const int SHB = SB + 6 * NSH;          // shell dof slots (tied ones are slaved)
  std::vector<int> beam_dof(6 * NB, -1);
  int M = SHB;
  for (std::size_t b = 0; b < NB; ++b)
    for (int c = 0; c < 6; ++c) {
      if (welded[b]) continue;                 // ALL SIX slaved onto a shell node
      if (c < 3 && tied[b]) continue;          // translations slaved onto a hex
      beam_dof[6 * b + static_cast<std::size_t>(c)] = M++;
    }

  // A beam or shell local DOF maps to either one master or (tied translation) eight.
  struct Map { int n = 0; std::array<int, 8> dof{}; std::array<double, 8> w{}; };
  auto shell_map = [&](int sid, int c) {
    Map m;
    if (c < 3 && shell_tied[static_cast<std::size_t>(sid)]) {
      for (int a = 0; a < 8; ++a) {
        m.dof[static_cast<std::size_t>(a)] =
            3 * shell_host[static_cast<std::size_t>(sid)][static_cast<std::size_t>(a)] + c;
        m.w[static_cast<std::size_t>(a)] =
            shell_w[static_cast<std::size_t>(sid)].weight[static_cast<std::size_t>(a)];
      }
      m.n = 8;
    } else {
      m.dof[0] = SB + 6 * sid + c;
      m.w[0] = 1.0;
      m.n = 1;
    }
    return m;
  };
  auto map_of = [&](std::size_t b, int c) {
    Map m;
    if (welded[b]) return shell_map(weld_to[b], c);  // through the skin's own tie
    if (c < 3 && tied[b]) {
      for (int a = 0; a < 8; ++a) {
        m.dof[static_cast<std::size_t>(a)] =
            3 * tie_node[b][static_cast<std::size_t>(a)] + c;
        m.w[static_cast<std::size_t>(a)] = tie_w[b].weight[static_cast<std::size_t>(a)];
      }
      m.n = 8;
    } else {
      m.dof[0] = beam_dof[6 * b + static_cast<std::size_t>(c)];
      m.w[0] = 1.0;
      m.n = 1;
    }
    return m;
  };

  mark("dof numbering", static_cast<double>(M));
  // ── assemble ─────────────────────────────────────────────────────────────
  Sparse K;
  const Hex8Stiffness Kh = hex8_stiffness(youngs_modulus, poisson, grid.spacing);
  for (std::size_t e : hex_cells) {
    const int i = static_cast<int>(e % grid.nx);
    const int j = static_cast<int>((e / grid.nx) % grid.ny);
    const int k = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) * grid.ny));
    int n8[8];
    int at = 0;
    for (int dk = 0; dk < 2; ++dk)
      for (int dj = 0; dj < 2; ++dj)
        for (int di = 0; di < 2; ++di)
          n8[at++] = nid[node_index(i + di, j + dj, k + dk)];
    // ★ REMAP TO CORE'S CORNER ORDER. hex8_stiffness uses BOTTOM-CCW-THEN-TOP-CCW
    // ((-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1), then the same at +1); the loop above
    // produces x-fastest-then-y. They differ by swapping corners 2<->3 and 6<->7.
    // Getting this wrong is NOT obviously wrong: on a symmetric block it showed up
    // as a 6% error against PL/(AE), well inside the range a coarse mesh could
    // plausibly explain.
    {
      const int ccw[8] = {0, 1, 3, 2, 4, 5, 7, 6};
      int tmp[8];
      for (int a = 0; a < 8; ++a) tmp[a] = n8[ccw[a]];
      for (int a = 0; a < 8; ++a) n8[a] = tmp[a];
    }
    // Element stiffness is exactly linear in the modulus, so the partial fill is a
    // scalar on the assembled element -- no second element type, no re-integration.
    double fill = 1.0;
    if (hex_solid_fraction) {
      fill = (*hex_solid_fraction)[e];
      if (!(fill > kHexFractionFloor)) fill = kHexFractionFloor;
      if (fill > 1.0) fill = 1.0;
    }
    for (int a = 0; a < 8; ++a)
      for (int ca = 0; ca < 3; ++ca)
        for (int b2 = 0; b2 < 8; ++b2)
          for (int cb = 0; cb < 3; ++cb)
            K.add(3 * n8[a] + ca, 3 * n8[b2] + cb, fill * Kh(3 * a + ca, 3 * b2 + cb));
  }

  // ── ★ ASSEMBLE THE SHELLS ─────────────────────────────────────────────────
  if (shells) {
    for (std::size_t pidx = 0; pidx < shells->size(); ++pidx) {
      const ShellPatch& sp2 = (*shells)[pidx];
      const double th = (sp2.thickness_mm > 0.0) ? sp2.thickness_mm
                                                 : sp2.mesh.thickness_mm;
      if (!(th > 0.0)) { out.refusal = "shell patch has no thickness"; return out; }
      const int base = shell_base[pidx];
      // the patch's own frame: local (u, w) in-plane, normal out of plane
      const Vec3& eu = sp2.mesh.basis_u;
      const Vec3& ew = sp2.mesh.basis_w;
      const Vec3& en = sp2.mesh.normal;
      const double R[9] = {eu.x, eu.y, eu.z, ew.x, ew.y, ew.z, en.x, en.y, en.z};
      for (const ShellMesh::Tri& tri : sp2.mesh.triangles) {
        const int n3[3] = {tri.a, tri.b, tri.c};
        double lx[3], ly[3];
        for (int a = 0; a < 3; ++a) {
          lx[a] = sp2.mesh.local_u[static_cast<std::size_t>(n3[a])];
          ly[a] = sp2.mesh.local_w[static_cast<std::size_t>(n3[a])];
        }
        const ShellStiffness Ke = shell3_stiffness(lx, ly, youngs_modulus, poisson, th);
        // rotate the 18x18 from the patch frame to global: block-diagonal in R,
        // one 3x3 block per (translation, rotation) triple per node
        double T[18][18] = {};
        for (int blk = 0; blk < 6; ++blk)
          for (int r2 = 0; r2 < 3; ++r2)
            for (int c2 = 0; c2 < 3; ++c2)
              T[3 * blk + r2][3 * blk + c2] = R[3 * r2 + c2];
        double Kg[18][18] = {};
        for (int a = 0; a < 18; ++a)
          for (int b2 = 0; b2 < 18; ++b2) {
            double acc = 0.0;
            for (int q = 0; q < 18; ++q)
              for (int w2 = 0; w2 < 18; ++w2)
                acc += T[q][a] * Ke(q, w2) * T[w2][b2];
            Kg[a][b2] = acc;
          }
        for (int a = 0; a < 18; ++a) {
          const Map ma = shell_map(base + n3[a / 6], a % 6);
          for (int b2 = 0; b2 < 18; ++b2) {
            if (Kg[a][b2] == 0.0) continue;
            const Map mb = shell_map(base + n3[b2 / 6], b2 % 6);
            for (int xi = 0; xi < ma.n; ++xi)
              for (int yi = 0; yi < mb.n; ++yi)
                K.add(ma.dof[static_cast<std::size_t>(xi)], mb.dof[static_cast<std::size_t>(yi)],
                      ma.w[static_cast<std::size_t>(xi)] * mb.w[static_cast<std::size_t>(yi)] *
                          Kg[a][b2]);
          }
        }
      }
    }
  }

  mark("shell assembly", static_cast<double>(out.shell_triangles));
  const double G = youngs_modulus / (2.0 * (1.0 + poisson));
  std::vector<FrameStiffness> member_k(net.member_count());
  std::vector<std::array<double, 9>> member_R(net.member_count());
  for (std::size_t mi = 0; mi < net.member_count(); ++mi) {
    const BeamNetwork::Member& m = net.members[mi];
    const Vec3& pa = net.nodes[static_cast<std::size_t>(m.node_a)];
    const Vec3& pb = net.nodes[static_cast<std::size_t>(m.node_b)];
    const double dx = pb.x - pa.x, dy = pb.y - pa.y, dz = pb.z - pa.z;
    const double L = std::sqrt(dx * dx + dy * dy + dz * dz);
    if (!(L > 0.0)) { out.refusal = "zero-length member"; return out; }
    const BeamSection sec = beam_section_circular(m.radius_mm);
    member_k[mi] = frame2_stiffness(youngs_modulus, G, sec.area, sec.inertia,
                                    sec.inertia, sec.torsion_j, L, shear_k);
    // local frame: ex along the member, ey/ez any consistent perpendicular pair
    double ex[3] = {dx / L, dy / L, dz / L};
    double up[3] = {0.0, 0.0, 1.0};
    if (std::fabs(ex[2]) > 0.999) { up[1] = 1.0; up[2] = 0.0; }
    double ez[3] = {ex[1] * up[2] - ex[2] * up[1], ex[2] * up[0] - ex[0] * up[2],
                    ex[0] * up[1] - ex[1] * up[0]};
    const double zn = std::sqrt(ez[0] * ez[0] + ez[1] * ez[1] + ez[2] * ez[2]);
    for (double& v : ez) v /= zn;
    const double ey[3] = {ez[1] * ex[2] - ez[2] * ex[1], ez[2] * ex[0] - ez[0] * ex[2],
                          ez[0] * ex[1] - ez[1] * ex[0]};
    member_R[mi] = {ex[0], ex[1], ex[2], ey[0], ey[1], ey[2], ez[0], ez[1], ez[2]};

    // Ke_global = T^T Ke_local T with T block-diagonal in R; scatter through the
    // tie maps in one pass.
    double Tg[12][12] = {};
    for (int blk = 0; blk < 4; ++blk)
      for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c)
          Tg[3 * blk + r][3 * blk + c] = member_R[mi][static_cast<std::size_t>(3 * r + c)];
    double Kg[12][12] = {};
    for (int a = 0; a < 12; ++a)
      for (int b2 = 0; b2 < 12; ++b2) {
        double acc = 0.0;
        for (int p = 0; p < 12; ++p)
          for (int q = 0; q < 12; ++q)
            acc += Tg[p][a] * member_k[mi](p, q) * Tg[q][b2];
        Kg[a][b2] = acc;
      }
    const std::size_t nodes2[2] = {static_cast<std::size_t>(m.node_a),
                                   static_cast<std::size_t>(m.node_b)};
    for (int a = 0; a < 12; ++a) {
      const Map ma = map_of(nodes2[a / 6], a % 6);
      for (int b2 = 0; b2 < 12; ++b2) {
        if (Kg[a][b2] == 0.0) continue;
        const Map mb = map_of(nodes2[b2 / 6], b2 % 6);
        for (int x = 0; x < ma.n; ++x)
          for (int y = 0; y < mb.n; ++y)
            K.add(ma.dof[static_cast<std::size_t>(x)], mb.dof[static_cast<std::size_t>(y)],
                  ma.w[static_cast<std::size_t>(x)] * mb.w[static_cast<std::size_t>(y)] *
                      Kg[a][b2]);
      }
    }
  }

  mark("beam assembly", static_cast<double>(net.member_count()));
  // ── BCs and loads on the solid nodes ─────────────────────────────────────
  std::vector<char> fixed(static_cast<std::size_t>(M), 0);
  std::vector<double> F(static_cast<std::size_t>(M), 0.0);
  std::size_t nbc = 0, nld = 0;
  for (const DirichletBC& b : bcs) {
    if (b.node < 0 || static_cast<std::size_t>(b.node) >= nid.size()) continue;
    const int n = nid[static_cast<std::size_t>(b.node)];
    if (n < 0) continue;
    fixed[static_cast<std::size_t>(3 * n + b.component)] = 1;
    ++nbc;
  }
  for (const NodalLoad& l : loads) {
    if (l.node < 0 || static_cast<std::size_t>(l.node) >= nid.size()) continue;
    const int n = nid[static_cast<std::size_t>(l.node)];
    if (n < 0) continue;
    F[static_cast<std::size_t>(3 * n + l.component)] += l.value;
    ++nld;
  }
  if (nbc == 0) { out.refusal = "no support landed on the solid mesh"; return out; }
  if (nld == 0) { out.refusal = "no load landed on the solid mesh"; return out; }

  mark("bcs and loads", static_cast<double>(nbc + nld));
  // ── solve on the FREE dof: RCM reorder, IC(0) preconditioner, CG ─────────
  // The previous version masked fixed dof inside a full-size matrix and used a
  // Jacobi preconditioner. That is the crudest useful choice, and on a mixed
  // solid/beam system it is a poor one: hex stiffness scales as E*h (thousands)
  // while beam bending goes as EI/L^3 with I ~ 0.05 mm^4. Measured on a real
  // 6 mm lattice: 9,492 iterations, 598 s.
  Csr Afull = compress(K, M);
  {
    std::vector<double> dg(static_cast<std::size_t>(M), 0.0);
    for (int i = 0; i < M; ++i)
      for (int k = Afull.ptr[static_cast<std::size_t>(i)];
           k < Afull.ptr[static_cast<std::size_t>(i) + 1]; ++k)
        if (Afull.idx[static_cast<std::size_t>(k)] == i)
          dg[static_cast<std::size_t>(i)] += Afull.val[static_cast<std::size_t>(k)];
    for (int i = 0; i < M; ++i)
      if (!(dg[static_cast<std::size_t>(i)] > 0.0)) fixed[static_cast<std::size_t>(i)] = 1;
  }
  std::vector<int> to_free(static_cast<std::size_t>(M), -1);
  std::vector<int> from_free;
  for (int i = 0; i < M; ++i)
    if (!fixed[static_cast<std::size_t>(i)]) {
      to_free[static_cast<std::size_t>(i)] = static_cast<int>(from_free.size());
      from_free.push_back(i);
    }
  const int NF = static_cast<int>(from_free.size());
  if (NF == 0) { out.refusal = "every degree of freedom is constrained"; return out; }

  Sparse Sf;
  for (int i = 0; i < M; ++i) {
    const int fi = to_free[static_cast<std::size_t>(i)];
    if (fi < 0) continue;
    for (int k = Afull.ptr[static_cast<std::size_t>(i)];
         k < Afull.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
      const int fj = to_free[static_cast<std::size_t>(Afull.idx[static_cast<std::size_t>(k)])];
      if (fj >= 0) Sf.add(fi, fj, Afull.val[static_cast<std::size_t>(k)]);
    }
  }
  Csr Af = compress(Sf, NF);

  // RCM: renumber so the tie coupling sits near the diagonal, which is what makes
  // IC(0) -- a factorisation restricted to A's own sparsity -- a good approximation.
  // ★ IS IT ACTUALLY SYMMETRIC? Conjugate gradients REQUIRES it, and nothing here
  // checked. An asymmetric system produces exactly the behaviour observed on a real
  // part: the residual descends for a while and then climbs away, which reads as
  // "ill-conditioned" and is not. Assembly is under two seconds on this problem, so
  // verifying is free next to a solve that would otherwise run for an hour and lie.
  {
    // ACCUMULATE FIRST. compress() scatters triplets without summing duplicates,
    // and assembly produces many entries per (i, j) -- CG sums them correctly in its
    // row loop, but comparing individual TRIPLETS against a single transpose partner
    // reports asymmetry on a matrix that is perfectly symmetric. (It did: 1.34 on a
    // system whose elements are symmetric to 4e-17.)
    std::map<std::pair<int,int>, double> acc;
    double scale = 0.0;
    for (int i = 0; i < NF; ++i)
      for (int k = Af.ptr[static_cast<std::size_t>(i)];
           k < Af.ptr[static_cast<std::size_t>(i) + 1]; ++k)
        acc[{i, Af.idx[static_cast<std::size_t>(k)]}] += Af.val[static_cast<std::size_t>(k)];
    for (const auto& kv : acc) scale = std::max(scale, std::fabs(kv.second));
    double worst = 0.0;
    for (const auto& kv : acc) {
      const int i = kv.first.first, j = kv.first.second;
      if (i == j) continue;
      const auto it2 = acc.find({j, i});
      const double other = (it2 == acc.end()) ? 0.0 : it2->second;
      worst = std::max(worst, std::fabs(kv.second - other));
    }
    out.matrix_asymmetry = (scale > 0.0) ? worst / scale : 0.0;
    if (out.matrix_asymmetry > 1e-9) {
      out.refusal = "the assembled matrix is NOT symmetric (relative asymmetry " +
                    std::to_string(out.matrix_asymmetry) +
                    "): conjugate gradients requires symmetry, and an asymmetric "
                    "system descends and then diverges rather than failing outright.";
      return out;
    }
  }
  // ★ IS EVERY FREE DOF CONNECTED TO A SUPPORTED ONE? The restraint checks above
  // interrogate the beam network and the shell patches SEPARATELY. Nothing asks the
  // assembled system whether it is one piece. A sub-assembly connected to nothing --
  // shell nodes that reach no tie, with beams welded to them -- is a free body: the
  // matrix stays positive SEMI-definite (p^T A p never goes negative, so the
  // indefiniteness test passes) and CG simply stagnates, because the load has a
  // component in the null space it can never remove. MEASURED: residual parked at
  // 1.3 for 5,500 iterations with a per-window rate of 1.00.
  {
    std::vector<int> par(static_cast<std::size_t>(NF));
    for (int i = 0; i < NF; ++i) par[static_cast<std::size_t>(i)] = i;
    std::function<int(int)> findp = [&](int x) {
      while (par[static_cast<std::size_t>(x)] != x) {
        par[static_cast<std::size_t>(x)] =
            par[static_cast<std::size_t>(par[static_cast<std::size_t>(x)])];
        x = par[static_cast<std::size_t>(x)];
      }
      return x;
    };
    for (int i = 0; i < NF; ++i)
      for (int k = Af.ptr[static_cast<std::size_t>(i)];
           k < Af.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = Af.idx[static_cast<std::size_t>(k)];
        const int a = findp(i), b2 = findp(j);
        if (a != b2) par[static_cast<std::size_t>(std::max(a, b2))] = std::min(a, b2);
      }
    // a component is SUPPORTED when it contains a dof adjacent to a fixed one
    std::set<int> supported;
    for (int i = 0; i < M; ++i) {
      if (!fixed[static_cast<std::size_t>(i)]) continue;
      for (int k = Afull.ptr[static_cast<std::size_t>(i)];
           k < Afull.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int fj = to_free[static_cast<std::size_t>(Afull.idx[static_cast<std::size_t>(k)])];
        if (fj >= 0) supported.insert(findp(fj));
      }
    }
    std::map<int, int> comp_size;
    for (int i = 0; i < NF; ++i) ++comp_size[findp(i)];
    std::size_t floating_dof = 0, floating_comps = 0;
    for (const auto& kv : comp_size)
      if (!supported.count(kv.first)) { floating_dof += static_cast<std::size_t>(kv.second); ++floating_comps; }
    out.floating_dof = floating_dof;
    if (floating_dof > 0) {
      out.refusal = std::to_string(floating_dof) + " of " + std::to_string(NF) +
                    " free dof lie in " + std::to_string(floating_comps) +
                    " sub-assembl(ies) that reach NO support. The matrix stays "
                    "positive semi-definite, so nothing diverges -- CG just stagnates "
                    "on the null space forever.";
      return out;
    }
  }
  mark("assembly connectivity", static_cast<double>(NF));
  mark("symmetry check", out.matrix_asymmetry);
  mark("free-free submatrix", static_cast<double>(Af.nnz()));
  const std::vector<int> perm = rcm_order(Af);
  std::vector<int> inv(static_cast<std::size_t>(NF), 0);
  for (int i = 0; i < NF; ++i) inv[static_cast<std::size_t>(perm[static_cast<std::size_t>(i)])] = i;
  Sparse Sp;
  for (int i = 0; i < NF; ++i)
    for (int k = Af.ptr[static_cast<std::size_t>(i)];
         k < Af.ptr[static_cast<std::size_t>(i) + 1]; ++k)
      Sp.add(inv[static_cast<std::size_t>(i)],
             inv[static_cast<std::size_t>(Af.idx[static_cast<std::size_t>(k)])],
             Af.val[static_cast<std::size_t>(k)]);
  Csr A = compress(Sp, NF);

  std::vector<double> Fp(static_cast<std::size_t>(NF), 0.0);
  for (int i = 0; i < NF; ++i)
    Fp[static_cast<std::size_t>(inv[static_cast<std::size_t>(i)])] =
        F[static_cast<std::size_t>(from_free[static_cast<std::size_t>(i)])];

  std::vector<double> diag(static_cast<std::size_t>(NF), 1.0);
  for (int i = 0; i < NF; ++i)
    for (int k = A.ptr[static_cast<std::size_t>(i)];
         k < A.ptr[static_cast<std::size_t>(i) + 1]; ++k)
      if (A.idx[static_cast<std::size_t>(k)] == i)
        diag[static_cast<std::size_t>(i)] = A.val[static_cast<std::size_t>(k)];

  // ★ IC(0) IS OFF BY DEFAULT, AND THAT IS A MEASUREMENT, NOT A PREFERENCE.
  // It looked like the obvious upgrade over Jacobi on a badly-conditioned mixed
  // system. MEASURED on the 6 mm lattice: Jacobi converged in 598 s; IC(0)+RCM was
  // killed after 1 h 29 m without finishing -- at least 9x slower. The factorisation
  // and its two sequential triangular solves per iteration cost more than the
  // iterations they save at this size. Kept, and reachable, because it may win on a
  // different shape; never enabled without measuring that shape.
  mark("RCM reordering", static_cast<double>(NF));
  // ★ SGS IS OFF BY DEFAULT, AND THAT IS A MEASUREMENT. It is the textbook step up
  // from Jacobi and it gives the EXACTLY correct answer on the block control
  // (8.570226e-05, identical). On the real part it DIVERGES: hex+beam went
  // 1.0 -> 0.19 -> 1.19 and the three-way model reached 3.3e4 in 1,000 iterations --
  // the same configuration Jacobi solves in 9,492. So the implementation is right on
  // a well-conditioned system and wrong, or inapplicable, on this one, and the cause
  // is not yet known. Shipping it as the default would have replaced a slow solve
  // with a broken one. TOPOPT_BEAM_PRECON=sgs to experiment.
  const char* pc = std::getenv("TOPOPT_BEAM_PRECON");
  const bool want_sgs = (pc && std::string(pc) == "sgs");
  SymGaussSeidel sgs;
  if (want_sgs) sgs.build(A);
  out.preconditioner = want_sgs ? "SGS" : "Jacobi";

  IncompleteCholesky ic;
  bool have_ic = false;
  if (const char* want = std::getenv("TOPOPT_BEAM_IC")) {
    if (std::string(want) == "1")
      for (double shift : {0.0, 1e-3, 1e-2, 1e-1, 1.0})
        if (ic.factor(A, shift)) { have_ic = true; out.ic_shift = shift; break; }
  }
  out.used_incomplete_cholesky = have_ic;

  mark("preconditioner", have_ic ? 1.0 : 0.0);
  std::vector<double> u(static_cast<std::size_t>(NF), 0.0), r = Fp,
      z(static_cast<std::size_t>(NF), 0.0), p(static_cast<std::size_t>(NF), 0.0),
      Ap(static_cast<std::size_t>(NF), 0.0);
  auto precondition = [&](const std::vector<double>& rr, std::vector<double>& zz) {
    if (have_ic) { ic.apply(rr, zz); return; }
    if (want_sgs) { sgs.apply(rr, zz); return; }
    zz.assign(static_cast<std::size_t>(NF), 0.0);
    for (int i = 0; i < NF; ++i)
      zz[static_cast<std::size_t>(i)] = rr[static_cast<std::size_t>(i)] /
                                        diag[static_cast<std::size_t>(i)];
  };
  double fnorm = 0.0;
  for (double v : r) fnorm += v * v;
  fnorm = std::sqrt(fnorm);
  if (!(fnorm > 0.0)) { out.refusal = "the applied load is zero on the free dof"; return out; }
  precondition(r, z);
  p = z;
  double rz = 0.0;
  for (int i = 0; i < NF; ++i) rz += r[static_cast<std::size_t>(i)] * z[static_cast<std::size_t>(i)];
  int it = 0;
  double rn = fnorm;
  bool aborted = false;
  const int every = (progress && progress->every > 0) ? progress->every : 100;
  for (; it < cg_max_iterations && rn > cg_tolerance * fnorm; ++it) {
    if (progress && progress->fn && (it % every) == 0) {
      if (!progress->fn(it, rn / fnorm, progress->user)) { aborted = true; break; }
    }
    A.multiply(p, Ap);
    double pAp = 0.0;
    for (int i = 0; i < NF; ++i) pAp += p[static_cast<std::size_t>(i)] * Ap[static_cast<std::size_t>(i)];
    // ★ THE DECISIVE TEST FOR INDEFINITENESS, and it is one line. p^T A p is the
    // curvature CG is descending along; for a POSITIVE SEMI-DEFINITE matrix it can
    // never be negative. If it is, the system is indefinite and no preconditioner
    // will help -- the model is wrong, not the solver. Distinguishing that from mere
    // ill-conditioning by watching a residual take an hour to misbehave is exactly
    // the confusion that has cost this codebase the most time.
    // ONLY TRUST THIS EARLY. After a long divergence the iterates are astronomically
    // large and p^T A p is a difference of enormous cancelling terms -- a negative
    // value then says nothing about the matrix. MEASURED: it reported -8.2e12 at
    // iteration 67,585 on a run whose residual had already reached 2e5, which is
    // numerical noise, not negative curvature. Gate on the residual still being O(1).
    if (pAp < 0.0 && rn < 10.0 * fnorm) {
      out.refusal = "the system is INDEFINITE: p^T A p = " + std::to_string(pAp) +
                    " < 0 at iteration " + std::to_string(it) +
                    ". A positive semi-definite matrix cannot produce that, so this "
                    "is a modelling error, not a conditioning one -- no "
                    "preconditioner will fix it.";
      out.iterations = it;
      return out;
    }
    if (!(std::fabs(pAp) > 0.0)) break;
    const double alpha = rz / pAp;
    for (int i = 0; i < NF; ++i) {
      u[static_cast<std::size_t>(i)] += alpha * p[static_cast<std::size_t>(i)];
      r[static_cast<std::size_t>(i)] -= alpha * Ap[static_cast<std::size_t>(i)];
    }
    precondition(r, z);
    double rz2 = 0.0, r2 = 0.0;
    for (int i = 0; i < NF; ++i) {
      rz2 += r[static_cast<std::size_t>(i)] * z[static_cast<std::size_t>(i)];
      r2 += r[static_cast<std::size_t>(i)] * r[static_cast<std::size_t>(i)];
    }
    const double beta = rz2 / rz;
    rz = rz2;
    rn = std::sqrt(r2);
    for (int i = 0; i < NF; ++i)
      p[static_cast<std::size_t>(i)] = z[static_cast<std::size_t>(i)] +
                                       beta * p[static_cast<std::size_t>(i)];
  }
  std::vector<double> ufull(static_cast<std::size_t>(M), 0.0);
  for (int i = 0; i < NF; ++i)
    ufull[static_cast<std::size_t>(from_free[static_cast<std::size_t>(i)])] =
        u[static_cast<std::size_t>(inv[static_cast<std::size_t>(i)])];
  u = ufull;
  mark("CG", static_cast<double>(it));
  out.iterations = it;
  out.residual = rn / fnorm;
  if (progress && progress->fn) progress->fn(it, out.residual, progress->user);
  if (aborted) {
    out.refusal = "the solve was aborted by the caller at iteration " +
                  std::to_string(it) + " (relative residual " +
                  std::to_string(out.residual) + ")";
    return out;
  }
  if (!(out.residual <= cg_tolerance) || !std::isfinite(out.residual)) {
    out.refusal = "the solve did not converge (relative residual " +
                  std::to_string(out.residual) + ")";
    return out;
  }
  out.converged = true;

  // ── recover ──────────────────────────────────────────────────────────────
  out.solid_displacement.assign(static_cast<std::size_t>(SB), 0.0);
  for (int i = 0; i < SB; ++i) out.solid_displacement[static_cast<std::size_t>(i)] = u[static_cast<std::size_t>(i)];
  auto dof_value = [&](std::size_t b, int c) {
    if (welded[b]) {
      const Map ms = shell_map(weld_to[b], c);
      double acc = 0.0;
      for (int a = 0; a < ms.n; ++a)
        acc += ms.w[static_cast<std::size_t>(a)] * u[static_cast<std::size_t>(ms.dof[static_cast<std::size_t>(a)])];
      return acc;
    }
    if (c < 3 && tied[b]) {
      double acc = 0.0;
      for (int a = 0; a < 8; ++a)
        acc += tie_w[b].weight[static_cast<std::size_t>(a)] *
               u[static_cast<std::size_t>(3 * tie_node[b][static_cast<std::size_t>(a)] + c)];
      return acc;
    }
    return u[static_cast<std::size_t>(beam_dof[6 * b + static_cast<std::size_t>(c)])];
  };
  mark("recover displacements", static_cast<double>(M));
  out.member_stress_mpa.assign(net.member_count(), 0.0);
  for (std::size_t mi = 0; mi < net.member_count(); ++mi) {
    const BeamNetwork::Member& m = net.members[mi];
    const std::size_t nodes2[2] = {static_cast<std::size_t>(m.node_a),
                                   static_cast<std::size_t>(m.node_b)};
    std::array<double, 12> ug{};
    for (int a = 0; a < 12; ++a) ug[static_cast<std::size_t>(a)] = dof_value(nodes2[a / 6], a % 6);
    std::array<double, 12> ul{};
    for (int blk = 0; blk < 4; ++blk)
      for (int r2 = 0; r2 < 3; ++r2) {
        double acc = 0.0;
        for (int c = 0; c < 3; ++c)
          acc += member_R[mi][static_cast<std::size_t>(3 * r2 + c)] *
                 ug[static_cast<std::size_t>(3 * blk + c)];
        ul[static_cast<std::size_t>(3 * blk + r2)] = acc;
      }
    const double s = frame_member_peak_stress(member_k[mi], ul, m.radius_mm);
    out.member_stress_mpa[mi] = s;
    if (s > out.peak_member_stress_mpa) {
      out.peak_member_stress_mpa = s;
      out.peak_member = static_cast<int>(mi);
    }
  }
  mark("member stress recovery", static_cast<double>(net.member_count()));
  return out;
}

}  // namespace topopt
