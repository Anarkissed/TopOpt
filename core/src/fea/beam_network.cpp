#include "topopt/beam_network.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <array>
#include <map>
#include <unordered_map>
#include <string>
#include <chrono>
#include <numeric>
#include <functional>
#include <set>
#include <stdexcept>

#if defined(TOPOPT_HAVE_ACCELERATE)
#include <Accelerate/Accelerate.h>
#endif

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

std::vector<char> beam_network_bridges(const BeamNetwork& net) {
  const std::size_t NV = net.nodes.size(), NE = net.members.size();
  std::vector<char> is_bridge(NE, 0);
  if (NV == 0 || NE == 0) return is_bridge;
  // adjacency in CSR: each member appears once from each end, carrying its own id so
  // the search can tell two parallel members apart
  std::vector<int> start(NV + 1, 0);
  for (const auto& m : net.members) {
    ++start[static_cast<std::size_t>(m.node_a) + 1];
    ++start[static_cast<std::size_t>(m.node_b) + 1];
  }
  for (std::size_t i = 0; i < NV; ++i) start[i + 1] += start[i];
  std::vector<int> adj_v(2 * NE), adj_e(2 * NE), fill(start.begin(), start.end() - 1);
  for (std::size_t e = 0; e < NE; ++e) {
    const int a = net.members[e].node_a, b = net.members[e].node_b;
    adj_v[static_cast<std::size_t>(fill[static_cast<std::size_t>(a)])] = b;
    adj_e[static_cast<std::size_t>(fill[static_cast<std::size_t>(a)]++)] = static_cast<int>(e);
    adj_v[static_cast<std::size_t>(fill[static_cast<std::size_t>(b)])] = a;
    adj_e[static_cast<std::size_t>(fill[static_cast<std::size_t>(b)]++)] = static_cast<int>(e);
  }
  // Tarjan, ITERATIVE. A traced lattice is 70,000 nodes deep in places and a
  // recursive walk overflows the stack on the real part rather than on any fixture.
  std::vector<int> disc(NV, -1), low(NV, 0), cur(NV, 0), pe(NV, -1), stack;
  int timer = 0;
  for (std::size_t s0 = 0; s0 < NV; ++s0) {
    if (disc[s0] >= 0) continue;
    disc[s0] = low[s0] = timer++;
    cur[s0] = start[s0];
    pe[s0] = -1;
    stack.assign(1, static_cast<int>(s0));
    while (!stack.empty()) {
      const int u = stack.back();
      if (cur[static_cast<std::size_t>(u)] < start[static_cast<std::size_t>(u) + 1]) {
        const int idx = cur[static_cast<std::size_t>(u)]++;
        const int v = adj_v[static_cast<std::size_t>(idx)];
        const int e = adj_e[static_cast<std::size_t>(idx)];
        // ★ skip the exact EDGE we arrived by, not every edge back to the parent.
        // Skipping by parent NODE would call a pair of parallel members a bridge,
        // when removing either one leaves the other holding the join.
        if (e == pe[static_cast<std::size_t>(u)]) continue;
        if (disc[static_cast<std::size_t>(v)] >= 0) {
          low[static_cast<std::size_t>(u)] =
              std::min(low[static_cast<std::size_t>(u)], disc[static_cast<std::size_t>(v)]);
        } else {
          disc[static_cast<std::size_t>(v)] = low[static_cast<std::size_t>(v)] = timer++;
          pe[static_cast<std::size_t>(v)] = e;
          cur[static_cast<std::size_t>(v)] = start[static_cast<std::size_t>(v)];
          stack.push_back(v);
        }
      } else {
        stack.pop_back();
        if (!stack.empty()) {
          const int p = stack.back();
          low[static_cast<std::size_t>(p)] =
              std::min(low[static_cast<std::size_t>(p)], low[static_cast<std::size_t>(u)]);
          if (low[static_cast<std::size_t>(u)] > disc[static_cast<std::size_t>(p)] &&
              pe[static_cast<std::size_t>(u)] >= 0)
            is_bridge[static_cast<std::size_t>(pe[static_cast<std::size_t>(u)])] = 1;
        }
      }
    }
  }
  return is_bridge;
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

ShellMesh mesh_skin_midsurface(const VoxelGrid& grid, const std::vector<char>& skin_mask,
                               double weld_tol_mm, double design_thickness_mm) {
  ShellMesh m;
  if (skin_mask.size() != grid.voxel_count()) return m;
  const double h = grid.spacing;
  const double tol = weld_tol_mm > 0.0 ? weld_tol_mm : 0.75 * h;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  auto at = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= nx || j >= ny || k >= nz) return false;
    return skin_mask[grid.index(i, j, k)] != 0;
  };
  // ── which way is each skin cell THIN? ───────────────────────────────────────
  // The skin is a shell one or two cells deep; the direction in which the run of
  // skin through a cell is SHORTEST is the through-thickness direction, and the
  // plate lies across the other two. A cell on a side wall is thin across the wall;
  // a cell on the far face is thin along the region normal. Nothing has to know
  // which is which -- the geometry says so.
  const int step[3][3] = {{1,0,0},{0,1,0},{0,0,1}};
  std::vector<signed char> axis(grid.voxel_count(), -1);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!at(i, j, k)) continue;
        int best = -1, bestrun = 0;
        for (int a = 0; a < 3; ++a) {
          int run = 1;
          for (int d = 1;; ++d) {
            if (!at(i + step[a][0]*d, j + step[a][1]*d, k + step[a][2]*d)) break;
            ++run;
          }
          for (int d = 1;; ++d) {
            if (!at(i - step[a][0]*d, j - step[a][1]*d, k - step[a][2]*d)) break;
            ++run;
          }
          if (best < 0 || run < bestrun) { best = a; bestrun = run; }
        }
        axis[grid.index(i, j, k)] = static_cast<signed char>(best);
      }
  // ── one facet per RUN, at the run's centre, carrying the run's depth ────────
  // welded node store: a hash grid at the weld tolerance, so facets that meet at a
  // fold share nodes and the skin comes out as one connected shell
  std::unordered_map<long long, std::vector<int>> bucket;
  auto key_of = [&](int a, int b, int c) {
    return (static_cast<long long>(a) * 73856093LL) ^
           (static_cast<long long>(b) * 19349663LL) ^
           (static_cast<long long>(c) * 83492791LL);
  };
  auto node_of = [&](const Vec3& p) {
    const int ci = static_cast<int>(std::floor(p.x / tol));
    const int cj = static_cast<int>(std::floor(p.y / tol));
    const int ck = static_cast<int>(std::floor(p.z / tol));
    for (int di = -1; di <= 1; ++di)
      for (int dj = -1; dj <= 1; ++dj)
        for (int dk = -1; dk <= 1; ++dk) {
          auto it = bucket.find(key_of(ci + di, cj + dj, ck + dk));
          if (it == bucket.end()) continue;
          for (int id : it->second) {
            const Vec3& q = m.nodes[static_cast<std::size_t>(id)];
            const double dx = p.x-q.x, dy = p.y-q.y, dz = p.z-q.z;
            if (dx*dx + dy*dy + dz*dz <= tol*tol) return id;
          }
        }
    const int id = static_cast<int>(m.nodes.size());
    m.nodes.push_back(p);
    bucket[key_of(ci, cj, ck)].push_back(id);
    return id;
  };
  std::vector<char> done(grid.voxel_count(), 0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!at(i, j, k) || done[e]) continue;
        const int a = axis[e];
        if (a < 0) continue;
        // walk to the start of this cell's run, then to its end, taking only cells
        // that agree this is their thin direction
        int si = i, sj = j, sk = k;
        while (at(si - step[a][0], sj - step[a][1], sk - step[a][2]) &&
               axis[grid.index(si - step[a][0], sj - step[a][1], sk - step[a][2])] == a) {
          si -= step[a][0]; sj -= step[a][1]; sk -= step[a][2];
        }
        int run = 0, ei = si, ej = sj, ek = sk;
        while (at(ei, ej, ek) && axis[grid.index(ei, ej, ek)] == a) {
          done[grid.index(ei, ej, ek)] = 1;
          ++run;
          ei += step[a][0]; ej += step[a][1]; ek += step[a][2];
        }
        // the facet plane sits at the centre of the run; it spans the cell footprint
        const double cu = grid.origin.x + (si + 0.5) * h + step[a][0] * 0.5 * (run - 1) * h;
        const double cv = grid.origin.y + (sj + 0.5) * h + step[a][1] * 0.5 * (run - 1) * h;
        const double cw = grid.origin.z + (sk + 0.5) * h + step[a][2] * 0.5 * (run - 1) * h;
        const int u_ax = (a + 1) % 3, w_ax = (a + 2) % 3;
        auto corner = [&](int su, int sw) {
          Vec3 p{cu, cv, cw};
          double* xyz[3] = {&p.x, &p.y, &p.z};
          *xyz[u_ax] += su * 0.5 * h;
          *xyz[w_ax] += sw * 0.5 * h;
          return p;
        };
        const int c00 = node_of(corner(-1,-1)), c10 = node_of(corner(+1,-1));
        const int c11 = node_of(corner(+1,+1)), c01 = node_of(corner(-1,+1));
        // the DESIGNED thickness when the caller knows it; otherwise the run of
        // cells, which is the raster's opinion rounded to whole voxels
        const double th = design_thickness_mm > 0.0 ? design_thickness_mm : run * h;
        if (c00 != c10 && c10 != c11 && c00 != c11) {
          m.triangles.push_back({c00, c10, c11});
          m.tri_thickness.push_back(th);
        }
        if (c00 != c11 && c11 != c01 && c00 != c01) {
          m.triangles.push_back({c00, c11, c01});
          m.tri_thickness.push_back(th);
        }
      }
  // a folded shell has no single normal or basis; the assembly takes them per facet.
  // Report the mean thickness so a caller that ignores tri_thickness still gets mass
  // of the right order rather than zero.
  double tsum = 0.0;
  for (double t : m.tri_thickness) tsum += t;
  m.thickness_mm = m.tri_thickness.empty() ? 0.0 : tsum / static_cast<double>(m.tri_thickness.size());
  return m;
}

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
// connected.
//
// ★ THAT LAST SENTENCE USED TO READ "so nothing was wrong except the
// preconditioner", AND IT WAS WRONG. The mesh contained corner-hinged solid islands
// -- pieces touching the part at a single point, connected to a shared-node test and
// free to rotate at zero energy. No preconditioner can remove a null space. The
// parked residual was a mechanism, not conditioning, and this whole smoother was
// built chasing it. It is kept because it is a correct smoother and may earn its
// place on the CG fallback, but it never was the fix. See the island drop in
// solve_coupled_lattice.
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

// ── ★ THE BLOCK PRECONDITIONER ──────────────────────────────────────────────
// This is the structure the mixed-dimensional beam-solid literature prescribes
// (arXiv 2402.18414, 2606.06035) and the reason Jacobi and global SGS both fail
// here.
//
// THE DIAGNOSIS. Partition the dof into the SOLID block (hex, and shell where
// present) and the BEAM block. Each block is, on its own, an ordinary
// well-conditioned FE matrix -- hex stiffness scales as E*h, beam bending as
// EI/L^3 with I ~ 0.05 mm^4. It is the RATIO BETWEEN THE BLOCKS, four or more
// orders of magnitude, that wrecks the conditioning. A preconditioner built from
// the diagonal (Jacobi) or from a global sweep (SGS) sees one system and cannot
// represent that split: MEASURED, Jacobi parks at residual 2.0 after 20,500
// iterations and SGS diverges to 3.3e4 in 1,000, on a matrix that is symmetric,
// positive semi-definite and fully connected.
//
// THE FIX. Precondition each block SEPARATELY, so each is solved in its own scale:
//
//     M^-1 = [ A_ss^-1     0     ]
//            [   0      A_bb^-1  ]
//
// with each diagonal block approximated by its own symmetric Gauss-Seidel sweeps.
// This is block-Jacobi -- the first and simplest member of the family, dropping the
// off-diagonal coupling entirely. The published methods add a Schur-complement
// correction for that coupling (SIMPLE-type, with algebraic multigrid on the solid
// block); this deliberately does not, because the coupling term is only worth
// building once the block split itself is shown to help.
struct BlockPrecon {
  const Csr* A = nullptr;
  std::vector<char> in_beam;                  // per free-dof: which block
  std::vector<double> diag;
  int sweeps = 2;

  void build(const Csr& a, std::vector<char> beam_flag, int nsweeps) {
    A = &a;
    in_beam = std::move(beam_flag);
    sweeps = nsweeps;
    diag.assign(static_cast<std::size_t>(a.n), 0.0);
    for (int i = 0; i < a.n; ++i)
      for (int k = a.ptr[static_cast<std::size_t>(i)];
           k < a.ptr[static_cast<std::size_t>(i) + 1]; ++k)
        if (a.idx[static_cast<std::size_t>(k)] == i)
          diag[static_cast<std::size_t>(i)] += a.val[static_cast<std::size_t>(k)];
    for (double& d : diag) if (!(d > 0.0)) d = 1.0;
  }

  // Symmetric Gauss-Seidel sweeps RESTRICTED to one block: rows outside the block
  // are skipped and their couplings ignored, which is what makes this block-Jacobi
  // rather than a global sweep.
  void sweep_block(bool beam, const std::vector<double>& r, std::vector<double>& z) const {
    const Csr& a = *A;
    for (int pass = 0; pass < sweeps; ++pass) {
      for (int i = 0; i < a.n; ++i) {
        if ((in_beam[static_cast<std::size_t>(i)] != 0) != beam) continue;
        double acc = r[static_cast<std::size_t>(i)];
        for (int k = a.ptr[static_cast<std::size_t>(i)];
             k < a.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
          const int j = a.idx[static_cast<std::size_t>(k)];
          if (j == i) continue;
          if ((in_beam[static_cast<std::size_t>(j)] != 0) != beam) continue;  // block-local
          acc -= a.val[static_cast<std::size_t>(k)] * z[static_cast<std::size_t>(j)];
        }
        z[static_cast<std::size_t>(i)] = acc / diag[static_cast<std::size_t>(i)];
      }
      for (int i = a.n - 1; i >= 0; --i) {          // and the reverse sweep, for symmetry
        if ((in_beam[static_cast<std::size_t>(i)] != 0) != beam) continue;
        double acc = r[static_cast<std::size_t>(i)];
        for (int k = a.ptr[static_cast<std::size_t>(i)];
             k < a.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
          const int j = a.idx[static_cast<std::size_t>(k)];
          if (j == i) continue;
          if ((in_beam[static_cast<std::size_t>(j)] != 0) != beam) continue;
          acc -= a.val[static_cast<std::size_t>(k)] * z[static_cast<std::size_t>(j)];
        }
        z[static_cast<std::size_t>(i)] = acc / diag[static_cast<std::size_t>(i)];
      }
    }
  }

  // ── ★ THE SCHUR COMPLEMENT CORRECTION ────────────────────────────────────
  // Block-DIAGONAL preconditioning drops the coupling between the blocks entirely.
  // MEASURED: that alone took the residual to 0.156 -- ten times closer than Jacobi
  // ever reached -- and then diverged, because the dropped coupling is not small.
  //
  // The published form is block-TRIANGULAR (arXiv 2402.18414, a SIMPLE-type
  // factorisation). Writing the system as
  //
  //     [ A_ss  A_sb ] [ z_s ]   [ r_s ]
  //     [ A_bs  A_bb ] [ z_b ] = [ r_b ]
  //
  // the exact block factorisation is
  //
  //     z_s = A_ss^-1 (r_s - A_sb z_b),      z_b = S^-1 (r_b - A_bs A_ss^-1 r_s)
  //     with the Schur complement  S = A_bb - A_bs A_ss^-1 A_sb.
  //
  // S is never formed: it is APPROXIMATED by A_bb, which is what makes this
  // affordable and is exactly the approximation the paper makes. The correction is
  // the part that matters here -- the beam solve sees the load the solid has
  // already taken (r_b - A_bs z_s), and the solid solve is then corrected for what
  // the beams carry (r_s - A_sb z_b). Dropping either term is block-Jacobi again.
  void apply(const std::vector<double>& r, std::vector<double>& z) const {
    const Csr& a = *A;
    const int n = a.n;
    z.assign(static_cast<std::size_t>(n), 0.0);

    // 1. predict the SOLID block from its own residual
    sweep_block(false, r, z);

    // 2. the beam block sees what the solid has already absorbed:  r_b - A_bs z_s
    std::vector<double> rb(static_cast<std::size_t>(n), 0.0);
    for (int i = 0; i < n; ++i) {
      if (!in_beam[static_cast<std::size_t>(i)]) continue;
      double acc = r[static_cast<std::size_t>(i)];
      for (int k = a.ptr[static_cast<std::size_t>(i)];
           k < a.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = a.idx[static_cast<std::size_t>(k)];
        if (!in_beam[static_cast<std::size_t>(j)])            // the coupling block
          acc -= a.val[static_cast<std::size_t>(k)] * z[static_cast<std::size_t>(j)];
      }
      rb[static_cast<std::size_t>(i)] = acc;
    }
    sweep_block(true, rb, z);                  // z_b ~ A_bb^-1 (r_b - A_bs z_s)

    // 3. correct the solid for what the beams turned out to carry: r_s - A_sb z_b
    std::vector<double> rs(static_cast<std::size_t>(n), 0.0);
    for (int i = 0; i < n; ++i) {
      if (in_beam[static_cast<std::size_t>(i)]) continue;
      double acc = r[static_cast<std::size_t>(i)];
      for (int k = a.ptr[static_cast<std::size_t>(i)];
           k < a.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = a.idx[static_cast<std::size_t>(k)];
        if (in_beam[static_cast<std::size_t>(j)])
          acc -= a.val[static_cast<std::size_t>(k)] * z[static_cast<std::size_t>(j)];
      }
      rs[static_cast<std::size_t>(i)] = acc;
    }
    // recompute the solid block from the corrected residual, so the pass is
    // SYMMETRIC overall (solid, beam, solid) -- an unsymmetric preconditioner
    // breaks the Krylov theory CG rests on, which is how SGS failed here.
    for (int i = 0; i < n; ++i)
      if (!in_beam[static_cast<std::size_t>(i)]) z[static_cast<std::size_t>(i)] = 0.0;
    sweep_block(false, rs, z);
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
    const std::vector<ShellPatch>* shells, double load_reach_mm,
    const CgProgress* progress, const SolveStage* stage) {
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

  // ── ★ DROP THE SOLID ISLANDS THAT HANG ON A CORNER ───────────────────────
  // Two voxels meeting at an EDGE or a CORNER share a line or a point. They are
  // "connected" to any test that unions shared nodes, and they are a HINGE in the
  // physics: free to rotate about that contact at zero energy. A voxelised part
  // grows them wherever a surface steps diagonally.
  //
  // MEASURED on the real M2 part: 48,439 hex elements form ONE component by
  // shared-node connectivity and THIRTY-ONE by face connectivity -- one real body
  // at 97.08% that reaches the supports, and 30 specks totalling 2.92% that reach
  // no support at all, the largest 322 elements.
  //
  // Those specks were the null space. Every preconditioner -- Jacobi,
  // block-diagonal, block+Schur -- drove the residual to the same floor
  // (~0.15-0.2) and then diverged, and 86% of the leftover residual sat in the
  // SOLID, not the lattice. It is also why the physically WRONG model converged:
  // meshing the whole region as solid filled the diagonal gaps and welded the
  // hinges shut by accident.
  //
  // They carry no load, so they are dropped and counted, exactly as the caller
  // drops load-free beam members. Dropping a LOT of the part is a different
  // matter -- that means the mesh is genuinely hinged rather than speckled -- so
  // past kIslandRefuseFraction this refuses instead of quietly deleting material.
  constexpr double kIslandRefuseFraction = 0.05;
  std::vector<char> hex_use(hex_mask.begin(), hex_mask.end());
  {
    std::vector<int> comp(grid.voxel_count(), -1);
    std::vector<std::size_t> stack, members;
    std::vector<std::size_t> comp_size;
    int nc = 0;
    for (std::size_t seed = 0; seed < grid.voxel_count(); ++seed) {
      if (!hex_use[seed] || comp[seed] >= 0) continue;
      const int c = nc++;
      std::size_t count = 0;
      stack.assign(1, seed);
      comp[seed] = c;
      while (!stack.empty()) {
        const std::size_t e = stack.back();
        stack.pop_back();
        ++count;
        const int i = static_cast<int>(e % grid.nx);
        const int j = static_cast<int>((e / grid.nx) % grid.ny);
        const int k = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) * grid.ny));
        const int step[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
        for (const auto& d : step) {
          const int ni = i + d[0], nj = j + d[1], nk = k + d[2];
          if (ni < 0 || nj < 0 || nk < 0 || ni >= grid.nx || nj >= grid.ny || nk >= grid.nz)
            continue;
          const std::size_t f = grid.index(ni, nj, nk);
          if (!hex_use[f] || comp[f] >= 0) continue;
          comp[f] = c;
          stack.push_back(f);
        }
      }
      comp_size.push_back(count);
    }
    // A component is real if a Dirichlet node sits on one of its elements.
    std::vector<char> supported(static_cast<std::size_t>(nc), 0);
    for (const DirichletBC& b : bcs) {
      if (b.node < 0 ||
          static_cast<std::size_t>(b.node) >= static_cast<std::size_t>(NX) * NY * (grid.nz + 1))
        continue;
      const std::size_t nidx = static_cast<std::size_t>(b.node);
      const int i = static_cast<int>(nidx % NX);
      const int j = static_cast<int>((nidx / NX) % NY);
      const int k = static_cast<int>(nidx / (static_cast<std::size_t>(NX) * NY));
      for (int dk = -1; dk <= 0; ++dk)
        for (int dj = -1; dj <= 0; ++dj)
          for (int di = -1; di <= 0; ++di) {
            const int ci = i + di, cj = j + dj, ck = k + dk;
            if (ci < 0 || cj < 0 || ck < 0 || ci >= grid.nx || cj >= grid.ny || ck >= grid.nz)
              continue;
            const int c = comp[grid.index(ci, cj, ck)];
            if (c >= 0) supported[static_cast<std::size_t>(c)] = 1;
          }
    }
    std::size_t meshed = 0, dropped_elems = 0, dropped_comps = 0;
    for (std::size_t e = 0; e < grid.voxel_count(); ++e) {
      if (comp[e] < 0) continue;
      ++meshed;
      if (!supported[static_cast<std::size_t>(comp[e])]) { hex_use[e] = 0; ++dropped_elems; }
    }
    for (int c = 0; c < nc; ++c)
      if (!supported[static_cast<std::size_t>(c)]) ++dropped_comps;
    out.solid_islands_dropped = dropped_comps;
    out.solid_islands_elements = dropped_elems;
    out.solid_islands_fraction = meshed ? static_cast<double>(dropped_elems) / static_cast<double>(meshed) : 0.0;
    if (out.solid_islands_fraction > kIslandRefuseFraction) {
      out.refusal =
          std::to_string(dropped_comps) + " solid piece(s) totalling " +
          std::to_string(dropped_elems) + " element(s) (" +
          std::to_string(100.0 * out.solid_islands_fraction) +
          "% of the meshed solid) touch the rest of the part only at an edge or a "
          "corner and reach no support: they are hinges, not structure, and no "
          "preconditioner can solve past them. That is too much of the part to drop "
          "silently -- repair the mesh or re-voxelise finer.";
      return out;
    }
  }
  mark("solid islands dropped", static_cast<double>(out.solid_islands_elements));

  // ── number the solid nodes a meshed voxel touches ────────────────────────
  std::vector<int> nid(static_cast<std::size_t>(NX) * NY * (grid.nz + 1), -1);
  std::vector<std::size_t> hex_cells;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!hex_use[e]) continue;
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
        // ★ THE SEARCH MUST SCALE WITH THE PLATE, NOT WITH THE GRID. A fixed +/-1
        // voxel bonds a skin whose mid-surface sits half a cell off the interface and
        // finds NOTHING for one that sits a full cell off -- measured, a one-cell
        // skin bonded at 82% of its nodes and a two-cell skin at 0%, purely because
        // of how many voxels deep the raster made it. The mid-surface of a plate of
        // thickness t lies t/2 from the material it fuses to, so reach that far plus
        // the half-voxel of grid slack, and turn it into a cell span.
        const double th_here = (*shells)[pidx].thickness_mm > 0.0
                                   ? (*shells)[pidx].thickness_mm : sm2.thickness_mm;
        const double want = 0.5 * (th_here > 0.0 ? th_here : grid.spacing) + 0.5 * grid.spacing;
        const int span = std::max(1, static_cast<int>(std::ceil(want / grid.spacing)));
        int hi = -1, hj = -1, hk = -1;
        double best = -1.0;
        for (int dk = -span; dk <= span; ++dk)
          for (int dj = -span; dj <= span; ++dj)
            for (int di = -span; di <= span; ++di) {
              const int ci = i + di, cj = j + dj, ck = k + dk;
              if (ci < 0 || cj < 0 || ck < 0 || ci >= grid.nx || cj >= grid.ny ||
                  ck >= grid.nz) continue;
              if (!hex_use[grid.index(ci, cj, ck)]) continue;
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
  // ★ DIAGNOSTIC: TOPOPT_BEAM_SKIN_PINNED=1 slaves only the TRANSLATIONS of a beam
  // node welded to the skin, leaving its rotations free -- the same joint a
  // beam-to-HEX tie makes, because a solid element has no rotational dof to tie to.
  // It exists to separate two explanations of the same number: with the skin meshed
  // as hex the lattice is held at 6,738 PINNED points and peak strut stress is
  // 3.40 MPa; with the skin meshed as plates it is held at 7,115 RIGID welds and
  // reads 0.125 MPa. Nearly the same attachment count, so if joint type is the whole
  // difference this flag closes it.
  const bool skin_pinned = [] {
    const char* v = std::getenv("TOPOPT_BEAM_SKIN_PINNED");
    return v && std::string(v) == "1";
  }();
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
    // ★ A WELD MEANS THE STRUT REACHES THE PLATE, AND DISTANCE TO THE NEAREST SKIN
    // NODE DOES NOT MEASURE THAT. `reach` is a LATERAL mesh-spacing number -- 0.75 of
    // the longest triangle edge -- and using it as a NORMAL-offset test welds
    // anything within a mesh cell of the surface in ANY direction.
    //
    // My first guess was that one stretched triangle had inflated it. MEASURED, that
    // is false: the skin mesh is clean (median edge 5.95 mm, max 8.36 mm, so
    // reach = 6.27 mm). The real cause is geometric -- each lattice region is only
    // 12-13 mm deep, which puts its two skin patches ~10-11 mm apart, so EVERY strut
    // node between them is inside 6.27 mm of one of them. 22,122 of 22,252 beam
    // nodes -- 99.4%, the entire lattice -- were rigidly welded (all six dof) to two
    // plates they never touch, gluing the lattice into a stiff sandwich: peak strut
    // stress 0.2556 MPa against 3.397 MPa for the SAME geometry with the skin meshed
    // as hex, a factor of 13.
    //
    // The skin is a band `thickness` deep centred on the mid-surface, so a strut that
    // ends in it lies within about half a thickness of the plane. Gate on distance to
    // the patch PLANE (one thickness, generous), and keep the lateral radius for what
    // it is actually good for: choosing WHICH node to attach to, and rejecting a node
    // that is beside the patch rather than on it.
    mark("shell weld radius mm", reach);
    for (std::size_t b = 0; b < NB; ++b) {
      double best = reach; int hit = -1;
      for (std::size_t pidx = 0; pidx < shells->size(); ++pidx) {
        const ShellMesh& sm2 = (*shells)[pidx].mesh;
        if (sm2.nodes.empty()) continue;
        const double th = (*shells)[pidx].thickness_mm > 0.0
                              ? (*shells)[pidx].thickness_mm : sm2.thickness_mm;
        const Vec3& o2 = sm2.nodes[0];
        const double plane_d = std::fabs((net.nodes[b].x - o2.x) * sm2.normal.x +
                                         (net.nodes[b].y - o2.y) * sm2.normal.y +
                                         (net.nodes[b].z - o2.z) * sm2.normal.z);
        if (th > 0.0 && plane_d > th) continue;   // not in the skin band
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
            if (!hex_use[grid.index(ci, cj, ck)]) continue;
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
  out.restraint = beam_network_restraint(net, tied, skin_pinned ? nullptr : &welded);
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
    // ★ FACE ADJACENCY, NOT SHARED NODES. Two voxels meeting at an EDGE or a CORNER
    // share a line or a point: they are "connected" to a union-find over shared
    // nodes, and they are a HINGE in the physics -- free to rotate about that
    // contact at zero energy. MEASURED on the real part: 48,439 hex elements form
    // ONE component by shared-node connectivity and THIRTY-ONE by face
    // connectivity, so 30 pieces hang on a corner or an edge.
    //
    // That is the whole reason this solve never worked. Every preconditioner --
    // Jacobi, block-diagonal, block+Schur -- drove the residual to the same floor
    // (~0.15-0.2) and then diverged, because they were all resolving the same
    // solvable part and stalling on the same null space; 86% of the leftover
    // residual sat in the SOLID, not the lattice. It also explains why the
    // physically WRONG model converged: meshing the whole region as solid filled
    // the diagonal gaps and welded the hinges shut by accident.
    //
    // Connectivity is not restraint. This file already learned that for beam ties
    // and for untied components; the solid check was still asking "is there a
    // path" instead of "can it resist rotation".
    DisjointSet sc(static_cast<std::size_t>(NS));
    for (std::size_t e : hex_cells) {
      const int i = static_cast<int>(e % grid.nx);
      const int j = static_cast<int>((e / grid.nx) % grid.ny);
      const int k = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) * grid.ny));
      // unite this element's own eight nodes (it is a rigid block on its own)
      int first = -1;
      for (int dk = 0; dk < 2; ++dk)
        for (int dj = 0; dj < 2; ++dj)
          for (int di = 0; di < 2; ++di) {
            const int id = nid[node_index(i + di, j + dj, k + dk)];
            if (first < 0) first = id; else sc.unite(first, id);
          }
    }
    // and only join NEIGHBOURING elements that share a FACE
    std::size_t face_joins = 0;
    for (std::size_t e : hex_cells) {
      const int i = static_cast<int>(e % grid.nx);
      const int j = static_cast<int>((e / grid.nx) % grid.ny);
      const int k = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) * grid.ny));
      const int step[3][3] = {{1,0,0},{0,1,0},{0,0,1}};
      for (const auto& d : step) {
        const int ni = i + d[0], nj = j + d[1], nk = k + d[2];
        if (ni >= grid.nx || nj >= grid.ny || nk >= grid.nz) continue;
        if (!hex_use[grid.index(ni, nj, nk)]) continue;
        const int a = nid[node_index(i + d[0], j + d[1], k + d[2])];
        const int b2 = nid[node_index(i, j, k)];
        if (a >= 0 && b2 >= 0) { sc.unite(a, b2); ++face_joins; }
      }
    }
    (void)face_joins;
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
  // block membership: everything below SHB is solid or shell; the beam dof follow.
  // Tracked here rather than inferred later, because the RCM permutation and the
  // free-dof compaction both renumber and the block split has to survive them.
  std::vector<char> dof_is_beam;
  for (std::size_t b = 0; b < NB; ++b)
    for (int c = 0; c < 6; ++c) {
      if (welded[b] && (!skin_pinned || c < 3)) continue;  // slaved onto a shell node
      if (c < 3 && tied[b]) continue;          // translations slaved onto a hex
      beam_dof[6 * b + static_cast<std::size_t>(c)] = M++;
    }
  dof_is_beam.assign(static_cast<std::size_t>(M), 0);
  for (std::size_t b = 0; b < NB; ++b)
    for (int c = 0; c < 6; ++c) {
      const int d = beam_dof[6 * b + static_cast<std::size_t>(c)];
      if (d >= 0) dof_is_beam[static_cast<std::size_t>(d)] = 1;
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
    if (welded[b] && (!skin_pinned || c < 3))
      return shell_map(weld_to[b], c);              // through the skin's own tie
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
      // ★ EACH TRIANGLE IN ITS OWN FRAME, NOT THE PATCH'S. A flat-FACET shell is
      // defined that way -- every facet is planar even when the surface is not --
      // and taking the frame from the patch silently required the whole patch to lie
      // in one plane. That is why the skin could only ever be modelled as flat
      // sheets across the lattice region's faces, which is not where the skin is:
      // the real grade-to-solid is a ribbon around the region's SIDES plus a partial
      // sheet at its far face, and no single plane holds that.
      //
      // For an isotropic material the assembled GLOBAL stiffness does not depend on
      // which in-plane basis the element was built in, so on a flat patch this is
      // the same matrix as before -- it only stops constraining what a patch may be.
      std::size_t ti = 0;
      for (const ShellMesh::Tri& tri : sp2.mesh.triangles) {
        const int n3[3] = {tri.a, tri.b, tri.c};
        const Vec3& A3 = sp2.mesh.nodes[static_cast<std::size_t>(tri.a)];
        const Vec3& B3 = sp2.mesh.nodes[static_cast<std::size_t>(tri.b)];
        const Vec3& C3 = sp2.mesh.nodes[static_cast<std::size_t>(tri.c)];
        const Vec3 ab{B3.x - A3.x, B3.y - A3.y, B3.z - A3.z};
        const Vec3 ac{C3.x - A3.x, C3.y - A3.y, C3.z - A3.z};
        const double abl = std::sqrt(ab.x*ab.x + ab.y*ab.y + ab.z*ab.z);
        Vec3 nn{ab.y*ac.z - ab.z*ac.y, ab.z*ac.x - ab.x*ac.z, ab.x*ac.y - ab.y*ac.x};
        const double nl2 = std::sqrt(nn.x*nn.x + nn.y*nn.y + nn.z*nn.z);
        if (!(abl > 0.0) || !(nl2 > 0.0)) { ++ti; continue; }   // degenerate facet
        const Vec3 eu{ab.x/abl, ab.y/abl, ab.z/abl};
        const Vec3 en{nn.x/nl2, nn.y/nl2, nn.z/nl2};
        const Vec3 ew{en.y*eu.z - en.z*eu.y, en.z*eu.x - en.x*eu.z, en.x*eu.y - en.y*eu.x};
        const double R[9] = {eu.x, eu.y, eu.z, ew.x, ew.y, ew.z, en.x, en.y, en.z};
        const double lx[3] = {0.0, abl, ac.x*eu.x + ac.y*eu.y + ac.z*eu.z};
        const double ly[3] = {0.0, 0.0, ac.x*ew.x + ac.y*ew.y + ac.z*ew.z};
        // ★ PER-FACET THICKNESS when the mesh carries one. A skin derived from
        // voxels is one or two cells deep depending on where you stand, and calling
        // all of it one thickness would put material where there is none.
        const double tht = (ti < sp2.mesh.tri_thickness.size() &&
                            sp2.mesh.tri_thickness[ti] > 0.0)
                               ? sp2.mesh.tri_thickness[ti] : th;
        ++ti;
        const ShellStiffness Ke = shell3_stiffness(lx, ly, youngs_modulus, poisson, tht);
        // rotate the 18x18 from the facet frame to global: block-diagonal in R,
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
  double load_all = 0.0, load_lost = 0.0;
  for (const DirichletBC& b : bcs) {
    const bool ok = b.node >= 0 && static_cast<std::size_t>(b.node) < nid.size() &&
                    nid[static_cast<std::size_t>(b.node)] >= 0;
    if (!ok) { ++out.bcs_dropped; continue; }
    const int n = nid[static_cast<std::size_t>(b.node)];
    fixed[static_cast<std::size_t>(3 * n + b.component)] = 1;
    ++nbc;
  }
  // ── ★ A LOAD GOES WHERE THE MATERIAL IS, WHATEVER ELEMENT CARRIES IT ──────
  // Loads are declared on GRID NODES, and used to be applied only where a hex node
  // existed. In a model whose whole point is that some voxels carry beams and plates
  // instead of hex, that silently threw the force away: measured on the same part
  // and the same 5,973 loads, 31.8% of |F| went missing with the skin meshed as hex
  // and 54.1% with it meshed as plates. Both solves converged to 1e-13 and reported
  // healthy, because a part that is not pushed is quiet.
  //
  // So fall back: solid node, else the nearest SHELL node, else the nearest BEAM
  // node, within one cell. Both are applied through the same master-slave maps the
  // assembly uses, so a tied or welded node routes the force to its masters and the
  // total is preserved. Only a load with no material within a cell is dropped, and
  // that is counted and refused below rather than passed over.
  struct NearNode { int kind; int id; Vec3 pos; };   // kind 0 = shell, 1 = beam
  std::unordered_map<long long, std::vector<NearNode>> near;
  const double lh = grid.spacing;
  auto cell_key3 = [](long long a, long long b3, long long c3) {
    return (a * 73856093LL) ^ (b3 * 19349663LL) ^ (c3 * 83492791LL);
  };
  auto cell_key = [&](const Vec3& p) {
    return cell_key3(static_cast<long long>(std::floor(p.x / lh)),
                     static_cast<long long>(std::floor(p.y / lh)),
                     static_cast<long long>(std::floor(p.z / lh)));
  };
  if (NSH > 0)
    for (std::size_t pidx = 0; pidx < shells->size(); ++pidx) {
      const ShellMesh& sm3 = (*shells)[pidx].mesh;
      for (std::size_t n = 0; n < sm3.nodes.size(); ++n)
        near[cell_key(sm3.nodes[n])].push_back(
            {0, shell_base[pidx] + static_cast<int>(n), sm3.nodes[n]});
    }
  for (std::size_t b = 0; b < NB; ++b)
    near[cell_key(net.nodes[b])].push_back({1, static_cast<int>(b), net.nodes[b]});
  // ★ AND THE MEMBERS THEMSELVES. A face traction is carried by the material behind
  // the face; over a lattice that is a STRUT, and the strut usually passes BETWEEN
  // its end nodes rather than ending at the loaded point. Index each member by the
  // cells its ends and midpoint fall in, then place the load on the nearest point
  // ALONG it, split to its two ends by the linear shape functions so the total force
  // and its line of action are both preserved.
  const double reach = load_reach_mm > 0.0 ? load_reach_mm : lh;
  std::unordered_map<long long, std::vector<int>> memb;
  for (std::size_t m2 = 0; m2 < net.member_count(); ++m2) {
    const auto& mm2 = net.members[m2];
    const Vec3& A4 = net.nodes[static_cast<std::size_t>(mm2.node_a)];
    const Vec3& B4 = net.nodes[static_cast<std::size_t>(mm2.node_b)];
    const Vec3 mid{0.5*(A4.x+B4.x), 0.5*(A4.y+B4.y), 0.5*(A4.z+B4.z)};
    for (const Vec3& q : {A4, B4, mid}) memb[cell_key(q)].push_back(static_cast<int>(m2));
  }

  for (const NodalLoad& l : loads) {
    load_all += std::fabs(l.value);
    if (l.component < 0 || l.component > 2) { ++out.loads_dropped; load_lost += std::fabs(l.value); continue; }
    const bool on_solid = l.node >= 0 && static_cast<std::size_t>(l.node) < nid.size() &&
                          nid[static_cast<std::size_t>(l.node)] >= 0;
    if (on_solid) {
      const int n = nid[static_cast<std::size_t>(l.node)];
      F[static_cast<std::size_t>(3 * n + l.component)] += l.value;
      ++nld;
      continue;
    }
    if (l.node < 0 || static_cast<std::size_t>(l.node) >=
                          static_cast<std::size_t>(NX) * NY * (grid.nz + 1)) {
      ++out.loads_dropped; load_lost += std::fabs(l.value); continue;
    }
    const std::size_t nidx = static_cast<std::size_t>(l.node);
    const Vec3 p{grid.origin.x + static_cast<double>(nidx % NX) * lh,
                 grid.origin.y + static_cast<double>((nidx / NX) % NY) * lh,
                 grid.origin.z + static_cast<double>(nidx / (static_cast<std::size_t>(NX) * NY)) * lh};
    // nearest shell node first, then nearest beam node: a plate spreads a surface
    // traction better than a single strut end does
    int best_kind = -1, best_id = -1;
    double best_d2[2] = {lh * lh, lh * lh};
    int best_of[2] = {-1, -1};
    const long long ci = static_cast<long long>(std::floor(p.x / lh));
    const long long cj = static_cast<long long>(std::floor(p.y / lh));
    const long long ck = static_cast<long long>(std::floor(p.z / lh));
    for (int di = -1; di <= 1; ++di)
      for (int dj = -1; dj <= 1; ++dj)
        for (int dk = -1; dk <= 1; ++dk) {
          const auto it = near.find(cell_key3(ci + di, cj + dj, ck + dk));
          if (it == near.end()) continue;
          for (const NearNode& cand : it->second) {
            const double d2 = (p.x-cand.pos.x)*(p.x-cand.pos.x) +
                              (p.y-cand.pos.y)*(p.y-cand.pos.y) +
                              (p.z-cand.pos.z)*(p.z-cand.pos.z);
            if (d2 < best_d2[cand.kind]) { best_d2[cand.kind] = d2; best_of[cand.kind] = cand.id; }
          }
        }
    if (best_of[0] >= 0) { best_kind = 0; best_id = best_of[0]; }
    else if (best_of[1] >= 0) { best_kind = 1; best_id = best_of[1]; }
    if (best_kind >= 0) {
      const Map mm = (best_kind == 0) ? shell_map(best_id, l.component)
                                      : map_of(static_cast<std::size_t>(best_id), l.component);
      for (int x = 0; x < mm.n; ++x)
        F[static_cast<std::size_t>(mm.dof[static_cast<std::size_t>(x)])] +=
            l.value * mm.w[static_cast<std::size_t>(x)];
      ++nld;
      if (best_kind == 0) ++out.loads_on_shell; else ++out.loads_on_beam;
      out.load_reach_used_max =
          std::max(out.load_reach_used_max, std::sqrt(best_d2[best_kind]));
      continue;
    }
    // nothing ended at this point: find the nearest strut PASSING under it
    int hit_m = -1; double hit_t = 0.0, hit_d2 = reach * reach;
    const int span = static_cast<int>(std::ceil(reach / lh));
    for (int di = -span; di <= span; ++di)
      for (int dj = -span; dj <= span; ++dj)
        for (int dk = -span; dk <= span; ++dk) {
          const auto it = memb.find(cell_key3(ci + di, cj + dj, ck + dk));
          if (it == memb.end()) continue;
          for (int m3 : it->second) {
            const auto& mm3 = net.members[static_cast<std::size_t>(m3)];
            const Vec3& A5 = net.nodes[static_cast<std::size_t>(mm3.node_a)];
            const Vec3& B5 = net.nodes[static_cast<std::size_t>(mm3.node_b)];
            const double ex = B5.x-A5.x, ey = B5.y-A5.y, ez = B5.z-A5.z;
            const double L2 = ex*ex + ey*ey + ez*ez;
            double t = 0.0;
            if (L2 > 0.0) t = ((p.x-A5.x)*ex + (p.y-A5.y)*ey + (p.z-A5.z)*ez) / L2;
            t = std::min(1.0, std::max(0.0, t));
            const double qx = A5.x + t*ex, qy = A5.y + t*ey, qz = A5.z + t*ez;
            const double d2 = (p.x-qx)*(p.x-qx) + (p.y-qy)*(p.y-qy) + (p.z-qz)*(p.z-qz);
            if (d2 < hit_d2) { hit_d2 = d2; hit_m = m3; hit_t = t; }
          }
        }
    if (hit_m < 0) { ++out.loads_dropped; load_lost += std::fabs(l.value); continue; }
    const auto& mmf = net.members[static_cast<std::size_t>(hit_m)];
    const std::size_t ends[2] = {static_cast<std::size_t>(mmf.node_a),
                                 static_cast<std::size_t>(mmf.node_b)};
    const double wt[2] = {1.0 - hit_t, hit_t};
    for (int e2 = 0; e2 < 2; ++e2) {
      if (wt[e2] == 0.0) continue;
      const Map mm4 = map_of(ends[e2], l.component);
      for (int x = 0; x < mm4.n; ++x)
        F[static_cast<std::size_t>(mm4.dof[static_cast<std::size_t>(x)])] +=
            l.value * wt[e2] * mm4.w[static_cast<std::size_t>(x)];
    }
    ++nld;
    ++out.loads_on_beam;
    out.load_reach_used_max = std::max(out.load_reach_used_max, std::sqrt(hit_d2));
  }
  out.bcs_applied = nbc;
  out.loads_applied = nld;
  out.load_dropped_fraction = load_all > 0.0 ? load_lost / load_all : 0.0;
  // ★ REFUSE A MODEL THAT LOST ITS LOAD. Solving the part with a share of the force
  // missing gives a stiffer, quieter answer that converges beautifully and means
  // nothing -- the failure is invisible precisely because everything else looks
  // healthy. Loads land on SOLID nodes only; a load applied where the mesh now
  // carries plates or beams instead has to be moved there, not dropped.
  // ★ 5% IS A MAINTAINER CHOICE, NOT A DERIVED BOUND. Nothing measured says the
  // error from 4.9% of missing force is tolerable and 5.1% is not; the number exists
  // so that a small unplaceable remainder does not stop a run while a large one does.
  // What makes it safe is that the fraction is REPORTED on every run whatever it is
  // (`load_dropped_fraction`, printed by the driver even at 0.00%), so a run that
  // lost 4.9% cannot look identical to one that lost none. Revisit it with a
  // measurement of how peak strut stress moves with the dropped fraction; until then
  // it is a guard rail, not a result.
  constexpr double kLoadDropRefuseFraction = 0.05;
  if (out.load_dropped_fraction > kLoadDropRefuseFraction) {
    out.refusal = std::to_string(out.loads_dropped) + " of " +
                  std::to_string(loads.size()) + " load(s), carrying " +
                  std::to_string(100.0 * out.load_dropped_fraction) +
                  "% of the applied force, land on nodes that are not part of the "
                  "meshed solid, so the part would be solved with that force absent. "
                  "Apply them to whatever now occupies those voxels.";
    return out;
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
  // ── ★ CONSTRAIN THE SUB-ASSEMBLIES THAT REACH NO SUPPORT ─────────────────
  // A part of the assembled system that touches no support is a free body. The
  // matrix stays positive SEMI-definite, so nothing diverges and the indefiniteness
  // test passes -- CG just stagnates forever on a load component in the null space.
  // This used to REFUSE. Refusing is right when the floating part is a real chunk of
  // the model, and wrong when it is the handful of specks every real geometry grows:
  // meshing the skin from the cells the generator flagged produces 72 connected
  // pieces, and a few small ones sit out in the sparse interior touching neither the
  // kept solid nor a load-bearing strut.
  //
  // They carry no load, exactly like the corner-hinged solid islands and the
  // load-free beam members, so constrain them to zero and COUNT them. Past
  // kFloatRefuseFraction that is no longer a speck and it refuses instead, because
  // silently pinning a real piece of the part would report a stiffness for a
  // structure that was never solved.
  constexpr double kFloatRefuseFraction = 0.05;
  {
    std::vector<int> par(static_cast<std::size_t>(M));
    for (int i = 0; i < M; ++i) par[static_cast<std::size_t>(i)] = i;
    std::function<int(int)> findp = [&](int x) {
      while (par[static_cast<std::size_t>(x)] != x) {
        par[static_cast<std::size_t>(x)] =
            par[static_cast<std::size_t>(par[static_cast<std::size_t>(x)])];
        x = par[static_cast<std::size_t>(x)];
      }
      return x;
    };
    for (int i = 0; i < M; ++i) {
      if (fixed[static_cast<std::size_t>(i)]) continue;
      for (int k = Afull.ptr[static_cast<std::size_t>(i)];
           k < Afull.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = Afull.idx[static_cast<std::size_t>(k)];
        if (fixed[static_cast<std::size_t>(j)]) continue;
        const int a = findp(i), b2 = findp(j);
        if (a != b2) par[static_cast<std::size_t>(std::max(a, b2))] = std::min(a, b2);
      }
    }
    std::set<int> supported;
    for (int i = 0; i < M; ++i) {
      if (!fixed[static_cast<std::size_t>(i)]) continue;
      for (int k = Afull.ptr[static_cast<std::size_t>(i)];
           k < Afull.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = Afull.idx[static_cast<std::size_t>(k)];
        if (!fixed[static_cast<std::size_t>(j)]) supported.insert(findp(j));
      }
    }
    std::size_t free_before = 0, floating = 0;
    for (int i = 0; i < M; ++i) if (!fixed[static_cast<std::size_t>(i)]) ++free_before;
    std::set<int> float_roots;
    for (int i = 0; i < M; ++i) {
      if (fixed[static_cast<std::size_t>(i)]) continue;
      const int r = findp(i);
      if (supported.count(r)) continue;
      float_roots.insert(r);
      ++floating;
    }
    out.floating_dof = floating;
    const double frac = free_before ? static_cast<double>(floating) /
                                      static_cast<double>(free_before) : 0.0;
    if (frac > kFloatRefuseFraction) {
      out.refusal = std::to_string(floating) + " of " + std::to_string(free_before) +
                    " free dof (" + std::to_string(100.0 * frac) + "%) lie in " +
                    std::to_string(float_roots.size()) +
                    " sub-assembl(ies) that reach NO support: they are free bodies, "
                    "and that is too much of the model to pin silently. Tie them, or "
                    "leave them out of the mesh.";
      return out;
    }
    if (floating > 0)
      for (int i = 0; i < M; ++i)
        if (!fixed[static_cast<std::size_t>(i)] && !supported.count(findp(i)))
          fixed[static_cast<std::size_t>(i)] = 1;
    mark("unsupported sub-assemblies pinned", static_cast<double>(floating));
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
    // ★ A GUARD NOW, NOT THE ACTION. The pass above pins unsupported sub-assemblies
    // before compaction, so this should always find zero; if it ever does not, the
    // pinning logic is wrong and the solve must not proceed on a null space.
    if (floating_dof > 0) {
      out.floating_dof = floating_dof;
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
  std::vector<char> free_is_beam(static_cast<std::size_t>(NF), 0);
  for (int i = 0; i < NF; ++i)
    free_is_beam[static_cast<std::size_t>(i)] =
        dof_is_beam[static_cast<std::size_t>(from_free[static_cast<std::size_t>(i)])];
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

  std::vector<char> perm_is_beam(static_cast<std::size_t>(NF), 0);
  for (int i = 0; i < NF; ++i)
    perm_is_beam[static_cast<std::size_t>(inv[static_cast<std::size_t>(i)])] =
        free_is_beam[static_cast<std::size_t>(i)];
  std::vector<double> Fp(static_cast<std::size_t>(NF), 0.0);
  for (int i = 0; i < NF; ++i)
    Fp[static_cast<std::size_t>(inv[static_cast<std::size_t>(i)])] =
        F[static_cast<std::size_t>(from_free[static_cast<std::size_t>(i)])];

  // ── ★ THE FAST PATH: A DIRECT SPARSE CHOLESKY ────────────────────────────
  // With the corner-hinged islands gone the free-free matrix is genuinely SPD, and
  // once a matrix is SPD the honest question is not "which preconditioner" but "why
  // iterate at all". This system is ~300k dof with ~10.6M non-zeros; Accelerate's
  // supernodal Cholesky factors that once and back-substitutes, giving the EXACT
  // answer with no tolerance, no iteration count and no convergence to argue about.
  //
  // It is also the only method whose cost does not depend on conditioning -- which
  // is the whole trouble with this system: it mixes hex (stiffness ~ E*h), beam
  // bending (~ E*I/L^3) and shell terms whose magnitudes differ by orders, and every
  // iterative scheme pays for that spread on every iteration.
  //
  // The symbolic stage predicts the factor size before any memory is committed, so a
  // part whose fill-in would not fit falls back to CG rather than being killed by
  // the OOM reaper.
  // the residual a DIRECT factorisation must reach to be believed. Not a stopping
  // rule -- a factorisation does not iterate -- but an accuracy floor: below this the
  // answer is exact for engineering purposes, and above it something is wrong.
  constexpr double kDirectAcceptResidual = 1e-6;
  bool direct_ok = false;
  const char* direct_which = "Cholesky";
  std::vector<double> u_direct;
  double direct_rn = 0.0, direct_factor_gb = 0.0;
  const char* pc_env = std::getenv("TOPOPT_BEAM_PRECON");
  const std::string pc_sel = pc_env ? std::string(pc_env) : std::string("direct");
#if defined(TOPOPT_HAVE_ACCELERATE)
  if (pc_sel == "direct" || pc_sel == "cholesky") {
    // lower triangle in coordinate form; Accelerate sums duplicates itself
    std::vector<int> ri, ci;
    std::vector<double> va;
    ri.reserve(static_cast<std::size_t>(A.nnz() / 2 + NF));
    ci.reserve(ri.capacity());
    va.reserve(ri.capacity());
    for (int i = 0; i < NF; ++i)
      for (int k = A.ptr[static_cast<std::size_t>(i)];
           k < A.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
        const int j = A.idx[static_cast<std::size_t>(k)];
        if (j > i) continue;                       // keep the lower triangle only
        ri.push_back(i);
        ci.push_back(j);
        va.push_back(A.val[static_cast<std::size_t>(k)]);
      }
    // ★ WHAT DOES THE DIAGONAL LOOK LIKE? A Cholesky that aborts with
    // SparseFactorizationFailed hit a non-positive pivot; the diagonal is the first
    // place to look, and its spread is also the conditioning number that matters.
    {
      double dmin = 0.0, dmax = 0.0;
      int nonpos = 0;
      bool first = true;
      for (int i = 0; i < NF; ++i)
        for (int k = A.ptr[static_cast<std::size_t>(i)];
             k < A.ptr[static_cast<std::size_t>(i) + 1]; ++k)
          if (A.idx[static_cast<std::size_t>(k)] == i) {
            const double d = A.val[static_cast<std::size_t>(k)];
            if (d <= 0.0) ++nonpos;
            if (first) { dmin = dmax = d; first = false; }
            dmin = std::min(dmin, d);
            dmax = std::max(dmax, d);
          }
      mark("diagonal min", dmin);
      mark("diagonal max", dmax);
      mark("non-positive diagonals", static_cast<double>(nonpos));
    }
    SparseAttributes_t attr{};
    attr.kind = SparseSymmetric;
    attr.triangle = SparseLowerTriangle;
    SparseMatrix_Double Amat = SparseConvertFromCoordinate(
        NF, NF, static_cast<long>(va.size()), 1, attr, ri.data(), ci.data(), va.data());
    SparseSymbolicFactorOptions sopt{};
    sopt.control = SparseDefaultControl;
    sopt.orderMethod = SparseOrderAMD;   // fill-reducing; the RCM order above is for CG
    sopt.order = nullptr;
    sopt.ignoreRowsAndColumns = nullptr;
    sopt.malloc = malloc;
    sopt.free = free;
    sopt.reportError = nullptr;
    // ★ LDLT BY DEFAULT, AND THAT IS A MEASUREMENT. Cholesky is the cheaper
    // factorisation and the obvious first choice for a stiffness matrix, but it
    // needs STRICT positive definiteness and it refused on every real model
    // measured -- SparseFactorizationFailed, a non-positive pivot, on c6 (303k dof),
    // c3 (569k) and c3_r192 (1.05M) alike, while the diagonal itself is entirely
    // positive (min 79, max 15385 on c6) and CG still descends. The system is
    // marginally definite, not indefinite: rounding at a pivot, not a mechanism.
    // Trying it first therefore buys nothing and costs the whole failed elimination
    // -- 0.45 s at 303k dof, 42.32 s at 1.05M. LDLT needs only symmetry, is exact,
    // and the residual gate below is what actually decides the answer is kept.
    // TOPOPT_BEAM_PRECON=cholesky to try the other one and re-measure.
    const bool try_cholesky = (pc_env && std::string(pc_env) == "cholesky");
    SparseFactorization_t ftype =
        try_cholesky ? SparseFactorizationCholesky : SparseFactorizationLDLT;
    SparseOpaqueSymbolicFactorization sym = SparseFactor(ftype, Amat.structure, sopt);
    if (sym.status != SparseStatusOK)
      mark("symbolic factorization FAILED", static_cast<double>(sym.status));
    if (sym.status == SparseStatusOK) {
      direct_factor_gb = static_cast<double>(sym.factorSize_Double) / (1024.0 * 1024.0 * 1024.0);
      mark("symbolic factorization", direct_factor_gb);
      constexpr double kMaxFactorGb = 24.0;
      if (direct_factor_gb > kMaxFactorGb)
        mark("factor too large, falling back to CG", direct_factor_gb);
      if (direct_factor_gb <= kMaxFactorGb) {
        SparseNumericFactorOptions nopt{};
        nopt.control = SparseDefaultControl;
        nopt.scalingMethod = SparseScalingDefault;
        nopt.scaling = nullptr;
        nopt.pivotTolerance = 0.0;
        nopt.zeroTolerance = 0.0;
        SparseOpaqueFactorization_Double fac = SparseFactor(sym, Amat, nopt);
        const char* which = try_cholesky ? "Cholesky" : "LDLT";
        // ★ LDLT WHEN CHOLESKY REFUSES. Cholesky needs strict positive
        // definiteness; LDLT only needs symmetry, and it is just as exact and
        // essentially as fast. On the real part Cholesky aborts with a non-positive
        // pivot (SparseFactorizationFailed, 0.45 s in) while conjugate gradients
        // still descends, so the matrix is at worst marginally definite -- a
        // rounding-level pivot, not a mechanism. LDLT pivots through that instead of
        // giving up, and the residual measured below is what decides whether the
        // answer is kept, so nothing rests on which factorisation ran.
        if (fac.status != SparseStatusOK && try_cholesky) {
          mark("numeric Cholesky refused, trying LDLT", static_cast<double>(fac.status));
          SparseCleanup(fac);
          SparseCleanup(sym);
          sym = SparseFactor(SparseFactorizationLDLT, Amat.structure, sopt);
          fac = SparseFactor(sym, Amat, nopt);
          which = "LDLT";
          if (fac.status != SparseStatusOK)
            mark("numeric LDLT FAILED", static_cast<double>(fac.status));
        }
        if (fac.status == SparseStatusOK) {
          mark("numeric factorization", direct_factor_gb);
          u_direct = Fp;
          DenseVector_Double xb{NF, u_direct.data()};
          SparseSolve(fac, xb);
          // ★ MEASURE THE ANSWER, DO NOT TRUST IT. A direct solve reports no
          // residual of its own, so compute ||b - Ax|| / ||b|| here; a factorisation
          // that silently lost accuracy must not pass as an exact answer.
          double bn = 0.0, rr = 0.0;
          for (int i = 0; i < NF; ++i) {
            double ax = 0.0;
            for (int k = A.ptr[static_cast<std::size_t>(i)];
                 k < A.ptr[static_cast<std::size_t>(i) + 1]; ++k)
              ax += A.val[static_cast<std::size_t>(k)] *
                    u_direct[static_cast<std::size_t>(A.idx[static_cast<std::size_t>(k)])];
            const double b = Fp[static_cast<std::size_t>(i)];
            bn += b * b;
            rr += (b - ax) * (b - ax);
          }
          direct_rn = bn > 0.0 ? std::sqrt(rr) / std::sqrt(bn) : 0.0;
          // ★ A DIRECT SOLVE REPORTS NO RESIDUAL OF ITS OWN, SO GATE ON THE MEASURED
          // ONE. Accepting the answer because the factorisation returned OK is how a
          // wrong displacement field passes as exact. If it is not small, fall
          // through to CG rather than ship it.
          direct_ok = direct_rn < kDirectAcceptResidual;
          direct_which = which;
          mark(direct_ok ? "direct solve accepted" : "direct solve REJECTED (residual)",
               direct_rn);
        }
        SparseCleanup(fac);
      }
      SparseCleanup(sym);
    }
    SparseCleanup(Amat);
    if (direct_ok) {
      out.preconditioner = std::string("direct sparse ") + direct_which +
                           " (Accelerate, AMD, factor " +
                           std::to_string(direct_factor_gb) + " GB)";
      mark("direct solve", direct_rn);
    }
  }
#endif

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
  const std::string pcname = pc_sel;
  const bool want_sgs = !direct_ok && (pcname == "sgs");
  const bool want_block = !direct_ok && (pcname == "block");
  SymGaussSeidel sgs;
  if (want_sgs) sgs.build(A);
  BlockPrecon blk;
  std::size_t n_beam_dof = 0;
  if (want_block) {
    for (char c2 : perm_is_beam) n_beam_dof += c2 ? 1u : 0u;
    blk.build(A, perm_is_beam, 2);
  }
  if (!direct_ok)
  out.preconditioner = want_block ? ("block (" + std::to_string(n_beam_dof) + " beam / " +
                                     std::to_string(NF - static_cast<int>(n_beam_dof)) +
                                     " solid dof)")
                                  : (want_sgs ? "SGS" : "Jacobi");

  IncompleteCholesky ic;
  bool have_ic = false;
  if (const char* want = direct_ok ? nullptr : std::getenv("TOPOPT_BEAM_IC")) {
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
    if (want_block) { blk.apply(rr, zz); return; }
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
  // ★ KEEP THE BEST ITERATE. On this system CG descends to a floor and then diverges
  // -- the LAST iterate is noise, and attributing anything to it says nothing. The
  // floor is where everything resolvable has been resolved and what remains is the
  // part no solver can remove, so that is the iterate worth reporting from.
  std::vector<double> u_best;
  double rn_best = fnorm;
  const int every = (progress && progress->every > 0) ? progress->every : 100;
  for (; !direct_ok && it < cg_max_iterations && rn > cg_tolerance * fnorm; ++it) {
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
    if (rn < rn_best) { rn_best = rn; u_best = u; }
    for (int i = 0; i < NF; ++i)
      p[static_cast<std::size_t>(i)] = z[static_cast<std::size_t>(i)] +
                                       beta * p[static_cast<std::size_t>(i)];
  }
  // ★ ORDER MATTERS HERE, AND IT BIT ME. The direct solution and the best CG
  // iterate are both in PERMUTED FREE-DOF order (length NF). The scatter below
  // un-permutes and expands to full dof order (length M). Applying either restore
  // AFTER the scatter writes an NF-length vector in permuted order into a slot that
  // is read as M-length in original order: the block-extension test came out 94% low
  // and still reported "converged", because the residual was measured on the vector
  // that WAS correct. Restore first, scatter second.
  if (!u_best.empty() && rn_best < rn) { u.swap(u_best); rn = rn_best; }
  if (direct_ok) { u.swap(u_direct); rn = direct_rn * fnorm; }
  const std::vector<double> u_free = u;   // permuted free order, for the locator
  std::vector<double> ufull(static_cast<std::size_t>(M), 0.0);
  for (int i = 0; i < NF; ++i)
    ufull[static_cast<std::size_t>(from_free[static_cast<std::size_t>(i)])] =
        u[static_cast<std::size_t>(inv[static_cast<std::size_t>(i)])];
  u = ufull;
  // ── ★ WHERE IS THE MECHANISM? ─────────────────────────────────────────────
  // Three preconditioners -- Jacobi, block-diagonal, and block+Schur -- all drove
  // the residual to the SAME floor (~0.15-0.2) and then diverged. A better
  // preconditioner reaching a lower floor would mean conditioning; the same floor
  // every time means a NULL-SPACE component that no solver can remove.
  //
  // ★ ANSWERED: the null space was corner-hinged solid islands, found by counting
  // FACE-connected components (31) against shared-node components (1). This locator
  // pointed at the solid, but its family shares were computed on a MIS-INDEXED
  // vector -- it multiplied the NF x NF matrix by the full-length displacement -- so
  // it pointed the right way by luck, and the finding rests on the component count,
  // not on this. Fixed to use the permuted free-dof vector; kept because "where does
  // the residual live" is the right question to ask of any stalled solve.
  {
    // ★ u_free, NOT u. A is NF x NF in permuted order; u has already been expanded
    // to M in original order. Multiplying by it read the wrong entries and made the
    // attribution meaningless -- it is what produced the "solid 85.8%" figure that
    // sent me looking at the hex mesh. The corner-hinge finding was confirmed
    // independently by counting face-connected components, not by this number.
    std::vector<double> rf(static_cast<std::size_t>(NF), 0.0);
    A.multiply(u_free, rf);
    for (int i = 0; i < NF; ++i)
      rf[static_cast<std::size_t>(i)] = Fp[static_cast<std::size_t>(i)] -
                                        rf[static_cast<std::size_t>(i)];
    // undo the RCM permutation, then attribute each dof back to its element family
    double solid_sq = 0.0, shell_sq = 0.0, beam_sq = 0.0, total_sq = 0.0;
    double worst = 0.0; int worst_dof = -1;
    for (int i = 0; i < NF; ++i) {
      const int orig = from_free[static_cast<std::size_t>(perm[static_cast<std::size_t>(i)])];
      const double v = rf[static_cast<std::size_t>(i)] * rf[static_cast<std::size_t>(i)];
      total_sq += v;
      if (v > worst) { worst = v; worst_dof = orig; }
      if (orig < SB) solid_sq += v;
      else if (orig < SHB) shell_sq += v;
      else beam_sq += v;
    }
    if (total_sq > 0.0) {
      out.residual_share_solid = solid_sq / total_sq;
      out.residual_share_shell = shell_sq / total_sq;
      out.residual_share_beam  = beam_sq / total_sq;
      out.worst_residual_dof = worst_dof;
      out.worst_residual_family =
          (worst_dof < SB) ? "solid" : (worst_dof < SHB ? "shell" : "beam");
      if (worst_dof >= SHB) {
        const int bd = worst_dof - SHB;
        // find which beam node owns it
        for (std::size_t b = 0; b < NB; ++b)
          for (int c = 0; c < 6; ++c)
            if (beam_dof[6 * b + static_cast<std::size_t>(c)] == worst_dof) {
              out.worst_residual_node = static_cast<int>(b);
              out.worst_residual_component = c;
            }
        (void)bd;
      } else if (worst_dof >= SB) {
        out.worst_residual_node = (worst_dof - SB) / 6;
        out.worst_residual_component = (worst_dof - SB) % 6;
      } else {
        out.worst_residual_node = worst_dof / 3;
        out.worst_residual_component = worst_dof % 3;
      }
    }
  }
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
  // ★ A DIRECT SOLVE IS NOT JUDGED BY A CG STOPPING TOLERANCE. cg_tolerance is the
  // point at which ITERATING stops being worth it; a factorisation cannot iterate to
  // tighten, so demanding it of one is a category error. It refused a perfectly good
  // answer on the 3 mm model -- "did not converge (relative residual 0.000000)", a
  // residual too small to print -- because the factorisation landed just above 1e-8.
  // The direct path already gates on a MEASURED residual (kDirectAcceptResidual);
  // this uses the same bar, and the iterative path keeps the caller's tolerance.
  const double accept = direct_ok ? kDirectAcceptResidual : cg_tolerance;
  if (!(out.residual <= accept) || !std::isfinite(out.residual)) {
    out.refusal = "the solve did not converge (relative residual " +
                  std::to_string(out.residual) + ", accepted below " +
                  std::to_string(accept) + ")";
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
  {
    double comp = 0.0;
    for (int i = 0; i < M; ++i)
      comp += F[static_cast<std::size_t>(i)] * u[static_cast<std::size_t>(i)];
    out.compliance = comp;
  }
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


// ══════════════════════════════════════════════════════════════════════════════
// ★★★ ORGANIC STRUCTURAL CERTIFICATION ★★★
// See beam_network.hpp for why this exists and what it refuses. Everything below is
// measured; nothing is asserted.
// ★ The share of MEMBERS that may carry exactly nothing before the organic
// certificate refuses rather than reporting a percentile over the remainder. Set to
// the same 5% as the solid island rule above, and for the same reason: below it the
// filter is removing noise, above it the filter is removing the part.
constexpr double kUncarriedRefuseFraction = 0.05;

OrganicCertificate certify_organic_structural(
    const VoxelGrid& grid, const std::vector<char>& hex_mask,
    const std::vector<BeamSegment>& spans, const std::vector<OrganicLoadCase>& cases,
    double youngs_modulus, double poisson, double allowable_mpa, double knockdown,
    double load_reach_mm, bool census_ok, const std::vector<ShellPatch>* shells) {
  OrganicCertificate cert;
  const auto t0 = std::chrono::steady_clock::now();
  auto finish = [&](void) {
    cert.seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    return cert;
  };
  auto refuse = [&](const std::string& why) {
    cert.verdict = OrganicCertificate::Verdict::Refused;
    cert.refusal = why;
    return finish();
  };

  // ── the preconditions, each a refusal and never a number ───────────────────
  if (!census_ok)
    return refuse(
        "the emission census has a stage that is null or absent, so this lattice's "
        "own pipeline cannot be shown to have run. A run that cannot say which passes "
        "executed is not certifiable.");
  if (spans.empty()) return refuse("no lattice geometry to certify");
  if (cases.empty())
    return refuse(
        "no load case was supplied. A certificate over zero load cases is a margin "
        "against nothing.");
  if (!(allowable_mpa > 0.0))
    return refuse("the material has no yield strength, so there is no allowable");
  if (!(knockdown > 0.0 && knockdown <= 1.0))
    return refuse("the interlayer knockdown must be in (0, 1]");

  cert.allowable_mpa = allowable_mpa;
  cert.knockdown_used = knockdown;
  cert.allowable_used_mpa = allowable_mpa * knockdown;

  const BeamNetwork net = build_beam_network(spans);
  cert.members = net.member_count();
  if (cert.members == 0) return refuse("the spans welded into an empty network");

  // ── EVERY load case, and the verdict is the WORST ───────────────────────────
  // The solid certificate runs them all; a lattice certified on one is certified
  // against a load the part will not only see.
  for (const OrganicLoadCase& lc : cases) {
    const CoupledLatticeSolve r = solve_coupled_lattice(
        grid, hex_mask, net, lc.bcs, lc.loads, youngs_modulus, poisson, 0.9, 1e-8,
        100000, nullptr, shells, load_reach_mm);
    ++cert.load_cases_run;
    cert.worst_load_dropped_fraction =
        std::max(cert.worst_load_dropped_fraction, r.load_dropped_fraction);
    if (!r.refusal.empty())
      return refuse("load case \"" + lc.name + "\": " + r.refusal);
    if (!r.converged)
      return refuse("load case \"" + lc.name +
                    "\": the solve did not converge, so its stresses mean nothing");

    // the distribution, over members that carry anything
    std::vector<double> ss;
    ss.reserve(r.member_stress_mpa.size());
    for (double v : r.member_stress_mpa)
      if (v > 0.0) ss.push_back(v);
    // ★ WHAT THE FILTER JUST REMOVED, before it is allowed to matter. A member at
    // exactly 0.0 is not a lightly-loaded member; it is a member the load never
    // reached, which on a disconnected network means a whole component. Reading
    // percentiles over the remainder would certify the loaded piece and report the
    // number as the part's.
    const double zero_frac =
        r.member_stress_mpa.empty()
            ? 0.0
            : 1.0 - static_cast<double>(ss.size()) /
                        static_cast<double>(r.member_stress_mpa.size());
    // recorded on the FIRST case unconditionally, then on any worse one, so the
    // number describes the run rather than only the cases that got worse
    if (cert.load_cases_run == 1 || zero_frac > cert.zero_stress_fraction) {
      cert.zero_stress_fraction = zero_frac;
      cert.members_carrying = static_cast<long long>(ss.size());
    }
    if (zero_frac > kUncarriedRefuseFraction)
      return refuse(
          "load case \"" + lc.name + "\": " +
          std::to_string(r.member_stress_mpa.size() - ss.size()) + " of " +
          std::to_string(r.member_stress_mpa.size()) + " members carry exactly no "
          "stress (" + std::to_string(zero_frac * 100.0) +
          "% carry nothing). The load does not reach that material, so a percentile "
          "taken over the members that DO carry would certify only the part of the "
          "lattice the load found, and report it as the whole. This is what a "
          "disconnected network looks like from inside the solver.");
    if (ss.empty())
      return refuse("load case \"" + lc.name +
                    "\": no strut carries any stress, which is not a lattice under "
                    "load — check that the load reached the geometry");
    std::sort(ss.begin(), ss.end());
    auto q = [&](double f) {
      return ss[static_cast<std::size_t>(f * static_cast<double>(ss.size() - 1))];
    };
    const double p99 = q(0.99);
    // ★ THE VERDICT READS p99, NOT THE MAX. The max is one member of tens of
    // thousands and nodal loads land on strut ENDS, which is where an artificial
    // peak appears; that artifact is not separated, so it is REPORTED and not read.
    if (p99 > cert.stress_used_mpa) {
      cert.stress_used_mpa = p99;
      cert.stress_p50_mpa = q(0.50);
      cert.stress_p95_mpa = q(0.95);
      cert.stress_p99_mpa = p99;
      cert.stress_max_mpa = ss.back();
      cert.governing_load_case = lc.name;
      int worst = -1;
      double wv = 0.0;
      for (std::size_t i = 0; i < r.member_stress_mpa.size(); ++i)
        if (r.member_stress_mpa[i] > wv) { wv = r.member_stress_mpa[i]; worst = static_cast<int>(i); }
      cert.worst_strut = worst;
    }
  }

  cert.verdict_statistic = "p99";
  cert.margin = cert.stress_used_mpa > 0.0
                    ? cert.allowable_used_mpa / cert.stress_used_mpa
                    : 0.0;
  cert.verdict = cert.margin >= 1.0 ? OrganicCertificate::Verdict::Certified
                                    : OrganicCertificate::Verdict::Refused;
  if (cert.verdict == OrganicCertificate::Verdict::Refused)
    cert.refusal =
        "the lattice is over its allowable: p99 strut stress " +
        std::to_string(cert.stress_used_mpa) + " MPa against " +
        std::to_string(cert.allowable_used_mpa) + " MPa allowed (" +
        std::to_string(allowable_mpa) + " yield x " + std::to_string(knockdown) +
        " knockdown), governed by load case \"" + cert.governing_load_case +
        "\", worst strut " + std::to_string(cert.worst_strut) + " at " +
        std::to_string(cert.stress_max_mpa) + " MPa.";
  return finish();
}

}  // namespace topopt
