#include "topopt/beam_network.hpp"

#include <algorithm>
#include <cmath>
#include <array>
#include <map>
#include <string>
#include <numeric>
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

BeamRestraintReport beam_network_restraint(const BeamNetwork& net,
                                           const std::vector<char>& node_tied) {
  if (node_tied.size() != net.nodes.size())
    throw std::invalid_argument("beam_network_restraint: node_tied size mismatch");

  BeamRestraintReport rep;
  rep.members_total = net.members.size();
  rep.member_unrestrained.assign(net.members.size(), 0);
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
  DisjointSet comp(net.nodes.size());
  for (const BeamNetwork::Member& m : net.members) comp.unite(m.node_a, m.node_b);
  std::map<int, bool> root_has_tie;
  for (std::size_t n = 0; n < net.nodes.size(); ++n) {
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
  return m;
}

}  // namespace

CoupledLatticeSolve solve_coupled_lattice(
    const VoxelGrid& grid, const std::vector<char>& hex_mask,
    const BeamNetwork& net, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, double youngs_modulus, double poisson,
    double shear_k, double cg_tolerance, int cg_max_iterations) {
  CoupledLatticeSolve out;
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

  // ── tie every beam node that lands in a meshed voxel ──────────────────────
  const std::size_t NB = net.node_count();
  std::vector<char> tied(NB, 0);
  std::vector<std::array<int, 8>> tie_node(NB);
  std::vector<FrameSolidTie> tie_w(NB);
  for (std::size_t b = 0; b < NB; ++b) {
    const Vec3& p = net.nodes[b];
    const int i = static_cast<int>(std::floor((p.x - grid.origin.x) / grid.spacing));
    const int j = static_cast<int>(std::floor((p.y - grid.origin.y) / grid.spacing));
    const int k = static_cast<int>(std::floor((p.z - grid.origin.z) / grid.spacing));
    if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz) continue;
    if (!hex_mask[grid.index(i, j, k)]) continue;
    const Vec3 org{grid.origin.x + i * grid.spacing, grid.origin.y + j * grid.spacing,
                   grid.origin.z + k * grid.spacing};
    tie_w[b] = frame_solid_tie(p, org, grid.spacing);
    // frame_solid_tie returns weights in x-fastest order; remap BOTH the weights
    // and the node ids into core's bottom-CCW-then-top-CCW order so a tie lands on
    // the same corner the element stiffness used.
    int raw_ids[8];
    int n = 0;
    bool ok = true;
    for (int dk = 0; dk < 2 && ok; ++dk)
      for (int dj = 0; dj < 2 && ok; ++dj)
        for (int di = 0; di < 2 && ok; ++di) {
          const int id = nid[node_index(i + di, j + dj, k + dk)];
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
    if (ok) { tied[b] = 1; ++out.beam_nodes_tied; }
  }

  // ── ★ RESTRAINT BEFORE FACTORISATION, not after it fails ─────────────────
  out.restraint = beam_network_restraint(net, tied);
  if (out.restraint.members_unrestrained > 0) {
    out.refusal = "the network contains " +
                  std::to_string(out.restraint.members_unrestrained) +
                  " unrestrained member(s): a pinned tie leaves them free to rotate, "
                  "so the system would be singular. Drop or restrain them first.";
    return out;
  }

  // ── master DOF: [3*NS solid][the beam dof that are NOT slaved] ────────────
  const int SB = 3 * NS;
  std::vector<int> beam_dof(6 * NB, -1);
  int M = SB;
  for (std::size_t b = 0; b < NB; ++b)
    for (int c = 0; c < 6; ++c) {
      if (c < 3 && tied[b]) continue;   // slaved onto the host element
      beam_dof[6 * b + static_cast<std::size_t>(c)] = M++;
    }

  // A beam local DOF maps to either one master or (tied translation) eight.
  struct Map { int n = 0; std::array<int, 8> dof{}; std::array<double, 8> w{}; };
  auto map_of = [&](std::size_t b, int c) {
    Map m;
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
    for (int a = 0; a < 8; ++a)
      for (int ca = 0; ca < 3; ++ca)
        for (int b2 = 0; b2 < 8; ++b2)
          for (int cb = 0; cb < 3; ++cb)
            K.add(3 * n8[a] + ca, 3 * n8[b2] + cb, Kh(3 * a + ca, 3 * b2 + cb));
  }

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

  // ── solve: Jacobi-preconditioned CG on the free DOF ──────────────────────
  Csr A = compress(K, M);
  std::vector<double> diag(static_cast<std::size_t>(M), 0.0);
  for (int i = 0; i < M; ++i)
    for (int k = A.ptr[static_cast<std::size_t>(i)];
         k < A.ptr[static_cast<std::size_t>(i) + 1]; ++k)
      if (A.idx[static_cast<std::size_t>(k)] == i)
        diag[static_cast<std::size_t>(i)] += A.val[static_cast<std::size_t>(k)];
  for (int i = 0; i < M; ++i)
    if (fixed[static_cast<std::size_t>(i)] || !(diag[static_cast<std::size_t>(i)] > 0.0))
      fixed[static_cast<std::size_t>(i)] = 1;

  auto mask_apply = [&](std::vector<double>& v) {
    for (int i = 0; i < M; ++i)
      if (fixed[static_cast<std::size_t>(i)]) v[static_cast<std::size_t>(i)] = 0.0;
  };
  std::vector<double> u(static_cast<std::size_t>(M), 0.0), r = F, z(static_cast<std::size_t>(M)),
      p(static_cast<std::size_t>(M)), Ap(static_cast<std::size_t>(M));
  mask_apply(r);
  double fnorm = 0.0;
  for (double v : r) fnorm += v * v;
  fnorm = std::sqrt(fnorm);
  if (!(fnorm > 0.0)) { out.refusal = "the applied load is zero on the free dof"; return out; }
  for (int i = 0; i < M; ++i)
    z[static_cast<std::size_t>(i)] =
        fixed[static_cast<std::size_t>(i)] ? 0.0
                                           : r[static_cast<std::size_t>(i)] /
                                                 diag[static_cast<std::size_t>(i)];
  p = z;
  double rz = 0.0;
  for (int i = 0; i < M; ++i) rz += r[static_cast<std::size_t>(i)] * z[static_cast<std::size_t>(i)];
  int it = 0;
  double rn = fnorm;
  for (; it < cg_max_iterations && rn > cg_tolerance * fnorm; ++it) {
    A.multiply(p, Ap);
    mask_apply(Ap);
    double pAp = 0.0;
    for (int i = 0; i < M; ++i) pAp += p[static_cast<std::size_t>(i)] * Ap[static_cast<std::size_t>(i)];
    if (!(std::fabs(pAp) > 0.0)) break;
    const double alpha = rz / pAp;
    for (int i = 0; i < M; ++i) {
      u[static_cast<std::size_t>(i)] += alpha * p[static_cast<std::size_t>(i)];
      r[static_cast<std::size_t>(i)] -= alpha * Ap[static_cast<std::size_t>(i)];
    }
    for (int i = 0; i < M; ++i)
      z[static_cast<std::size_t>(i)] =
          fixed[static_cast<std::size_t>(i)] ? 0.0
                                             : r[static_cast<std::size_t>(i)] /
                                                   diag[static_cast<std::size_t>(i)];
    double rz2 = 0.0, r2 = 0.0;
    for (int i = 0; i < M; ++i) {
      rz2 += r[static_cast<std::size_t>(i)] * z[static_cast<std::size_t>(i)];
      r2 += r[static_cast<std::size_t>(i)] * r[static_cast<std::size_t>(i)];
    }
    const double beta = rz2 / rz;
    rz = rz2;
    rn = std::sqrt(r2);
    for (int i = 0; i < M; ++i)
      p[static_cast<std::size_t>(i)] = z[static_cast<std::size_t>(i)] +
                                       beta * p[static_cast<std::size_t>(i)];
  }
  out.iterations = it;
  out.residual = rn / fnorm;
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
    if (c < 3 && tied[b]) {
      double acc = 0.0;
      for (int a = 0; a < 8; ++a)
        acc += tie_w[b].weight[static_cast<std::size_t>(a)] *
               u[static_cast<std::size_t>(3 * tie_node[b][static_cast<std::size_t>(a)] + c)];
      return acc;
    }
    return u[static_cast<std::size_t>(beam_dof[6 * b + static_cast<std::size_t>(c)])];
  };
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
  return out;
}

}  // namespace topopt
