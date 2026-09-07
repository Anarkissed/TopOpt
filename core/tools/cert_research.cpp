// cert_research — RESEARCH HARNESS (branch claude/research-device-certificate; nothing
// ships). Reloads a certificate input dump (TOPOPT_CERT_DUMP_DIR, run_job.cpp) and
// runs the coupled solve per VARIANT, per PROCESS, so /usr/bin/time -l isolates each
// variant's peak memory:
//   baseline        today's network, every segment a member
//   merge[:deg]     chains between junctions collapsed into one beam, split where the
//                   chain bends beyond `deg` (default 15); per-segment stress recovered
//                   from its merged member (see the note at recover_segments)
// Prints one JSON line with: members, dof, factor GB (symbolic), wall seconds, rss
// before/after/peak, p99 over segments and over members, the ratio-p99 verdict under
// the per-strut interlayer knockdown (the certificate's rule, replicated here), and
// writes per-segment stresses to <out>.stress for agreement checks between variants.
#include "topopt/beam_network.hpp"
#include "topopt/observability.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <string>
#include <vector>

using namespace topopt;

struct Dump {
  VoxelGrid grid;
  std::vector<char> mask;
  std::vector<BeamSegment> spans;
  std::vector<OrganicLoadCase> cases;
  double E = 0, nu = 0, yield = 0, zkd = 1;
  Vec3 build{0, 0, 1};
  double reach = 0;
  bool census_ok = true;
};

static Dump load_dump(const char* path) {
  Dump d;
  FILE* f = std::fopen(path, "r");
  if (!f) { std::fprintf(stderr, "cannot open %s\n", path); std::exit(2); }
  char tag[32];
  int nx, ny, nz;
  if (std::fscanf(f, "%31s %d %d %d %lf %lf %lf %lf", tag, &nx, &ny, &nz, &d.grid.spacing, &d.grid.origin.x,
                  &d.grid.origin.y, &d.grid.origin.z) != 8) std::exit(3);
  d.grid.nx = nx; d.grid.ny = ny; d.grid.nz = nz;
  d.grid.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag{});
  int census;
  if (std::fscanf(f, "%31s %lf %lf %lf %lf %lf %lf %lf %lf %d", tag, &d.E, &d.nu, &d.yield, &d.zkd, &d.build.x,
                  &d.build.y, &d.build.z, &d.reach, &census) != 10) std::exit(4);
  d.census_ok = census != 0;
  std::size_t n;
  if (std::fscanf(f, "%31s %zu", tag, &n) != 2) std::exit(5);
  d.mask.resize(n);
  int c = std::fgetc(f);
  while (c == '\n' || c == ' ') c = std::fgetc(f);
  for (std::size_t e = 0; e < n; ++e) { d.mask[e] = (c == '1'); c = std::fgetc(f); }
  if (std::fscanf(f, "%31s %zu", tag, &n) != 2) std::exit(6);
  d.spans.resize(n);
  for (std::size_t i = 0; i < n; ++i) {
    BeamSegment& s = d.spans[i];
    if (std::fscanf(f, "%lf %lf %lf %lf %lf %lf %lf %d", &s.a.x, &s.a.y, &s.a.z, &s.b.x, &s.b.y, &s.b.z,
                    &s.radius_mm, &s.tag) != 8) std::exit(7);
  }
  std::size_t nc;
  if (std::fscanf(f, "%31s %zu", tag, &nc) != 2) std::exit(8);
  d.cases.resize(nc);
  for (std::size_t k = 0; k < nc; ++k) {
    char name[256]; std::size_t nb, nl;
    if (std::fscanf(f, "%31s %255s %zu %zu", tag, name, &nb, &nl) != 4) std::exit(9);
    d.cases[k].name = name;
    d.cases[k].bcs.resize(nb); d.cases[k].loads.resize(nl);
    for (auto& b : d.cases[k].bcs) if (std::fscanf(f, "%d %d %lf", &b.node, &b.component, &b.value) != 3) std::exit(10);
    for (auto& l : d.cases[k].loads) if (std::fscanf(f, "%d %d %lf", &l.node, &l.component, &l.value) != 3) std::exit(11);
  }
  std::fclose(f);
  return d;
}

// ── CHAIN MERGING ─────────────────────────────────────────────────────────────
// Nodes come from build_beam_network (the weld the certificate uses). A node of
// degree 2 whose two members are within `deg` of collinear and share a radius is an
// interior point of a chain; the chain becomes one segment from its first to its
// last junction. `origin_of[merged]` lists the original member indices it replaced.
struct Merged {
  std::vector<BeamSegment> spans;
  std::vector<std::vector<int>> origin_of;   // merged index -> original member indices
  std::size_t members_before = 0;
};

static Merged merge_chains(const std::vector<BeamSegment>& spans, double deg) {
  const BeamNetwork net = build_beam_network(spans);
  Merged m;
  m.members_before = net.members.size();
  const std::size_t NN = net.nodes.size();
  std::vector<std::vector<int>> inc(NN);
  for (std::size_t i = 0; i < net.members.size(); ++i) {
    inc[static_cast<std::size_t>(net.members[i].node_a)].push_back(static_cast<int>(i));
    inc[static_cast<std::size_t>(net.members[i].node_b)].push_back(static_cast<int>(i));
  }
  auto dir = [&](int mi, int from) {
    const auto& mm = net.members[static_cast<std::size_t>(mi)];
    const int to = mm.node_a == from ? mm.node_b : mm.node_a;
    const Vec3& A = net.nodes[static_cast<std::size_t>(from)];
    const Vec3& B = net.nodes[static_cast<std::size_t>(to)];
    Vec3 d{B.x - A.x, B.y - A.y, B.z - A.z};
    const double L = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    if (L > 0) { d.x /= L; d.y /= L; d.z /= L; }
    return d;
  };
  const double cos_lim = std::cos(deg * 3.14159265358979323846 / 180.0);
  // a node is "pass-through" when degree 2, same radius, same tag, bend within deg
  std::vector<char> pass(NN, 0);
  for (std::size_t n = 0; n < NN; ++n) {
    if (inc[n].size() != 2) continue;
    const auto& m0 = net.members[static_cast<std::size_t>(inc[n][0])];
    const auto& m1 = net.members[static_cast<std::size_t>(inc[n][1])];
    if (std::fabs(m0.radius_mm - m1.radius_mm) > 1e-9 || m0.tag != m1.tag) continue;
    const Vec3 d0 = dir(inc[n][0], static_cast<int>(n)), d1 = dir(inc[n][1], static_cast<int>(n));
    // d0 and d1 both point AWAY from n; collinear means d0 ~ -d1
    const double c = -(d0.x * d1.x + d0.y * d1.y + d0.z * d1.z);
    if (c >= cos_lim) pass[n] = 1;
  }
  std::vector<char> used(net.members.size(), 0);
  for (std::size_t n = 0; n < NN; ++n) {
    if (pass[n]) continue;               // chains start at junctions / bends / ends
    for (int mi : inc[n]) {
      if (used[static_cast<std::size_t>(mi)]) continue;
      // walk from n through pass-through nodes
      std::vector<int> chain;
      int cur = static_cast<int>(n), mw = mi;
      while (true) {
        used[static_cast<std::size_t>(mw)] = 1;
        chain.push_back(mw);
        const auto& mm = net.members[static_cast<std::size_t>(mw)];
        const int nxt = mm.node_a == cur ? mm.node_b : mm.node_a;
        if (!pass[static_cast<std::size_t>(nxt)]) { cur = nxt; break; }
        const int m2 = inc[static_cast<std::size_t>(nxt)][0] == mw ? inc[static_cast<std::size_t>(nxt)][1]
                                                                    : inc[static_cast<std::size_t>(nxt)][0];
        if (used[static_cast<std::size_t>(m2)]) { cur = nxt; break; }
        cur = nxt; mw = m2;
      }
      const auto& first = net.members[static_cast<std::size_t>(chain.front())];
      BeamSegment s;
      s.a = net.nodes[static_cast<std::size_t>(n)];
      s.b = net.nodes[static_cast<std::size_t>(cur)];
      s.radius_mm = first.radius_mm;
      s.tag = first.tag;
      m.spans.push_back(s);
      m.origin_of.push_back(chain);
    }
  }
  // closed loops of pass-through nodes (no junction) would be missed: pick them up
  for (std::size_t i = 0; i < net.members.size(); ++i) {
    if (used[i]) continue;
    const auto& mm = net.members[i];
    BeamSegment s;
    s.a = net.nodes[static_cast<std::size_t>(mm.node_a)];
    s.b = net.nodes[static_cast<std::size_t>(mm.node_b)];
    s.radius_mm = mm.radius_mm; s.tag = mm.tag;
    m.spans.push_back(s); m.origin_of.push_back({static_cast<int>(i)}); used[i] = 1;
  }
  return m;
}

// The certificate's statistic, replicated: per member allowable = yield * min(1, z/cos^2).
struct Stat {
  double p50 = 0, p95 = 0, p99 = 0, max = 0;   // stress, MPa
  double ratio_p99 = 0, ratio_max = 0;         // stress / allowable_i
  double margin = 0;
  std::size_t n = 0;
  bool certified = false;
};

static Stat statistic(const BeamNetwork& net, const std::vector<double>& stress, const std::vector<char>& dropped,
                      double yield, double zkd, Vec3 build) {
  std::vector<double> ss, rr;
  for (std::size_t i = 0; i < stress.size(); ++i) {
    if (i < dropped.size() && dropped[i]) continue;
    if (!(stress[i] > 0)) continue;
    const auto& A = net.nodes[static_cast<std::size_t>(net.members[i].node_a)];
    const auto& B = net.nodes[static_cast<std::size_t>(net.members[i].node_b)];
    const double dx = B.x - A.x, dy = B.y - A.y, dz = B.z - A.z, L2 = dx * dx + dy * dy + dz * dz;
    double kd = 1.0;
    if (L2 > 0) {
      const double d = dx * build.x + dy * build.y + dz * build.z;
      const double c2 = d * d / L2;
      kd = c2 > zkd ? zkd / c2 : 1.0;
    }
    ss.push_back(stress[i]);
    rr.push_back(stress[i] / (yield * kd));
  }
  Stat st;
  st.n = ss.size();
  if (ss.empty()) return st;
  std::sort(ss.begin(), ss.end()); std::sort(rr.begin(), rr.end());
  auto q = [](const std::vector<double>& v, double f) { return v[static_cast<std::size_t>(f * static_cast<double>(v.size() - 1))]; };
  st.p50 = q(ss, 0.5); st.p95 = q(ss, 0.95); st.p99 = q(ss, 0.99); st.max = ss.back();
  st.ratio_p99 = q(rr, 0.99); st.ratio_max = rr.back();
  st.margin = st.ratio_p99 > 0 ? 1.0 / st.ratio_p99 : 0;
  st.certified = st.margin >= 1.0;
  return st;
}


// ── EXPORT-PATH VARIANTS: xbase, guyan[:maxI], submodel:<margin_vox> ──────────
struct FreeSys {
  CoupledResearchExport X;
  std::vector<double> Ff;           // RHS in free numbering
};
static FreeSys export_system(const Dump& d, const BeamNetwork& net) {
  FreeSys fs;
  fs.X.skip_solve = true;
  (void)solve_coupled_lattice(d.grid, d.mask, net, d.cases[0].bcs, d.cases[0].loads, d.E, d.nu, 0.9, 1e-8, 100000,
                              nullptr, nullptr, d.reach, nullptr, nullptr, false, &fs.X);
  fs.Ff.assign(static_cast<std::size_t>(fs.X.NF), 0.0);
  for (int i = 0; i < fs.X.NF; ++i) fs.Ff[static_cast<std::size_t>(i)] = fs.X.F[static_cast<std::size_t>(fs.X.from_free[static_cast<std::size_t>(i)])];
  return fs;
}
static std::vector<double> to_full(const CoupledResearchExport& X, const std::vector<double>& u_free) {
  std::vector<double> u(static_cast<std::size_t>(X.M), 0.0);
  for (int i = 0; i < X.NF; ++i) u[static_cast<std::size_t>(X.from_free[static_cast<std::size_t>(i)])] = u_free[static_cast<std::size_t>(i)];
  return u;
}
struct Agreement { double max_rel = 0, p99_ref = 0, p99_new = 0; std::size_t over1 = 0, over5 = 0, n = 0; };
static Agreement agree(const std::vector<double>& ref, const std::vector<double>& nw) {
  Agreement a;
  std::vector<double> r = ref; std::sort(r.begin(), r.end());
  a.p99_ref = r.empty() ? 0 : r[static_cast<std::size_t>(0.99 * static_cast<double>(r.size() - 1))];
  std::vector<double> q = nw; std::sort(q.begin(), q.end());
  a.p99_new = q.empty() ? 0 : q[static_cast<std::size_t>(0.99 * static_cast<double>(q.size() - 1))];
  const double floor = 0.01 * a.p99_ref;
  for (std::size_t i = 0; i < ref.size() && i < nw.size(); ++i) {
    if (!(ref[i] > floor)) continue;
    const double rel = std::fabs(nw[i] - ref[i]) / ref[i];
    a.max_rel = std::max(a.max_rel, rel); ++a.n;
    if (rel > 0.01) ++a.over1;
    if (rel > 0.05) ++a.over5;
  }
  return a;
}
// extract a sub-CSR on a dof subset (map: old -> new index or -1)
struct Sub { int n = 0; std::vector<int> ptr, idx; std::vector<double> val; };
static Sub sub_csr(const CoupledResearchExport& X, const std::vector<int>& map, int n) {
  Sub S; S.n = n; S.ptr.assign(static_cast<std::size_t>(n) + 1, 0);
  std::vector<std::vector<std::pair<int, double>>> rows(static_cast<std::size_t>(n));
  for (int i = 0; i < X.NF; ++i) {
    const int a = map[static_cast<std::size_t>(i)];
    if (a < 0) continue;
    for (int k = X.ptr[static_cast<std::size_t>(i)]; k < X.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
      const int b = map[static_cast<std::size_t>(X.idx[static_cast<std::size_t>(k)])];
      if (b < 0) continue;
      rows[static_cast<std::size_t>(a)].push_back({b, X.val[static_cast<std::size_t>(k)]});
    }
  }
  for (int a = 0; a < n; ++a) {
    S.ptr[static_cast<std::size_t>(a) + 1] = S.ptr[static_cast<std::size_t>(a)] + static_cast<int>(rows[static_cast<std::size_t>(a)].size());
    for (const auto& e : rows[static_cast<std::size_t>(a)]) { S.idx.push_back(e.first); S.val.push_back(e.second); }
  }
  return S;
}

// Stress at station t in [0,1] of a member from its local end forces: N is constant,
// the moment vector varies linearly between the ends (exact for a prismatic beam
// loaded only at its ends -- which is what a merged chain between junctions is).
static double stress_at_station(const double* f, double radius, double t) {
  const double area = M_PI * radius * radius, inertia = M_PI * radius * radius * radius * radius / 4.0;
  const double nA = f[0], nB = f[6];
  const double myA = f[4], mzA = f[5], myB = f[10], mzB = f[11];
  // end B's internal moment has the opposite sign convention to end A's (equilibrium): interpolate |M|
  // between the magnitudes at the two ends -- the envelope of a linear vector field is bounded by them
  const double bA = std::sqrt(myA * myA + mzA * mzA), bB = std::sqrt(myB * myB + mzB * mzB);
  const double n = std::fabs(nA) * (1.0 - t) + std::fabs(nB) * t;
  const double bend = (bA * (1.0 - t) + bB * t) * radius / inertia;
  return n / area + bend;
}
static const Merged* g_merged = nullptr;          // set by main for the *-merge variants
static const BeamNetwork* g_net0 = nullptr;       // the unmerged network (original members)
static int run_xbase(const Dump& d, const BeamNetwork& net, const std::string& outp, const std::string& variant) {
  const ProcessMemory m0 = process_memory();
  const auto t0 = std::chrono::steady_clock::now();
  FreeSys fs = export_system(d, net);
  const ResearchDirectSolve r = research_direct_solve(fs.X.NF, fs.X.ptr, fs.X.idx, fs.X.val, fs.Ff);
  const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  const ProcessMemory m1 = process_memory();
  if (!r.ok) { std::printf("{\"variant\": \"%s\", \"error\": \"%s\"}\n", variant.c_str(), r.note.c_str()); return 1; }
  const std::vector<double> u = to_full(fs.X, r.u);
  const std::vector<double> st = fs.X.recover(u);
  if (FILE* f = std::fopen((outp + ".u").c_str(), "wb")) { std::fwrite(u.data(), sizeof(double), u.size(), f); std::fclose(f); }
  if (FILE* f = std::fopen((outp + ".stress").c_str(), "w")) { for (double v : st) std::fprintf(f, "%.9g\n", v); std::fclose(f); }
  const std::vector<char> nodrop;
  const Stat sm = statistic(net, st, nodrop, d.yield, d.zkd, d.build);
  // merged: per-ORIGINAL-segment stress two ways -- the envelope (today's simple recovery)
  // and the station-wise value from the merged member's end forces
  std::string seg_json;
  if (g_merged && g_net0) {
    const std::vector<double> fl = fs.X.recover_forces(u);
    std::vector<double> env(g_net0->members.size(), 0.0), sta(g_net0->members.size(), 0.0);
    for (std::size_t j = 0; j < g_merged->origin_of.size() && j < st.size(); ++j) {
      const auto& chain = g_merged->origin_of[j];
      const BeamSegment& ms = g_merged->spans[j];
      const double Lx = ms.b.x - ms.a.x, Ly = ms.b.y - ms.a.y, Lz = ms.b.z - ms.a.z, L2 = Lx * Lx + Ly * Ly + Lz * Lz;
      for (int oi : chain) {
        env[static_cast<std::size_t>(oi)] = st[j];
        const auto& om = g_net0->members[static_cast<std::size_t>(oi)];
        const Vec3& A = g_net0->nodes[static_cast<std::size_t>(om.node_a)];
        const Vec3& B = g_net0->nodes[static_cast<std::size_t>(om.node_b)];
        const double mx = 0.5 * (A.x + B.x) - ms.a.x, my = 0.5 * (A.y + B.y) - ms.a.y, mz = 0.5 * (A.z + B.z) - ms.a.z;
        const double t = L2 > 0 ? std::min(1.0, std::max(0.0, (mx * Lx + my * Ly + mz * Lz) / L2)) : 0.5;
        sta[static_cast<std::size_t>(oi)] = stress_at_station(&fl[12 * j], ms.radius_mm, t);
      }
    }
    const Stat se = statistic(*g_net0, env, nodrop, d.yield, d.zkd, d.build);
    const Stat ss = statistic(*g_net0, sta, nodrop, d.yield, d.zkd, d.build);
    char b[400];
    std::snprintf(b, sizeof b, ", \"seg_envelope\": {\"n\": %zu, \"p99\": %.5g, \"max\": %.5g, \"margin\": %.4g, \"certified\": %s}"
                  ", \"seg_station\": {\"n\": %zu, \"p99\": %.5g, \"max\": %.5g, \"margin\": %.4g, \"certified\": %s}",
                  se.n, se.p99, se.max, se.margin, se.certified ? "true" : "false", ss.n, ss.p99, ss.max, ss.margin, ss.certified ? "true" : "false");
    seg_json = b;
    if (FILE* f = std::fopen((outp + ".segstress").c_str(), "w")) { for (double v : sta) std::fprintf(f, "%.9g\n", v); std::fclose(f); }
  }
  std::printf("{\"variant\": \"%s\", \"members\": %zu, \"dof_free\": %d, \"dof_full\": %d, \"nnz\": %zu, \"interface_solid_dofs\": %zu, "
              "\"factor_gb\": %.4f, \"assembly_s\": %.2f, \"factor_solve_s\": %.2f, \"wall_s\": %.2f, \"rss_before_mb\": %.0f, "
              "\"rss_after_mb\": %.0f, \"peak_rss_mb\": %.0f, \"mem\": {\"n\": %zu, \"p99\": %.5g, \"max\": %.5g, \"margin\": %.4g, \"certified\": %s}}\n",
              variant.c_str(), net.members.size(), fs.X.NF, fs.X.M, fs.X.val.size(), fs.X.tie_host_dofs.size(), r.factor_gb,
              fs.X.assembly_seconds, r.seconds, wall, m0.rss_mb, m1.rss_mb, m1.peak_rss_mb, sm.n, sm.p99, sm.max, sm.margin,
              sm.certified ? "true" : "false");
  if (!seg_json.empty()) std::printf("{\"variant\": \"%s\"%s}\n", variant.c_str(), seg_json.c_str());
  return 0;
}

static std::vector<double> read_stress(const std::string& path) {
  std::vector<double> v; FILE* f = std::fopen(path.c_str(), "r"); if (!f) return v;
  double x; while (std::fscanf(f, "%lf", &x) == 1) v.push_back(x); std::fclose(f); return v;
}

// GUYAN: interior solid e condensed onto r = interface I (solid dofs hosting ties) + beam.
static int run_guyan(const Dump& d, const BeamNetwork& net, const std::string& outp, const std::string& variant,
                     std::size_t max_interface, const std::string& ref_stress_path) {
  const ProcessMemory m0 = process_memory();
  const auto t0 = std::chrono::steady_clock::now();
  FreeSys fs = export_system(d, net);
  const CoupledResearchExport& X = fs.X;
  std::vector<char> is_iface(static_cast<std::size_t>(X.M), 0);
  for (int dd : X.tie_host_dofs) is_iface[static_cast<std::size_t>(dd)] = 1;
  // kinds in free numbering: 0 interior solid, 1 interface, 2 beam
  std::vector<int> kind(static_cast<std::size_t>(X.NF), 0);
  std::size_t nE = 0, nI = 0, nB = 0;
  for (int i = 0; i < X.NF; ++i) {
    const int full = X.from_free[static_cast<std::size_t>(i)];
    if (X.dof_is_beam[static_cast<std::size_t>(full)]) { kind[static_cast<std::size_t>(i)] = 2; ++nB; }
    else if (is_iface[static_cast<std::size_t>(full)]) { kind[static_cast<std::size_t>(i)] = 1; ++nI; }
    else ++nE;
  }
  // beam-interior coupling must be empty for the condensation to be exact on r
  std::size_t beam_interior_entries = 0;
  for (int i = 0; i < X.NF; ++i) {
    if (kind[static_cast<std::size_t>(i)] != 2) continue;
    for (int k = X.ptr[static_cast<std::size_t>(i)]; k < X.ptr[static_cast<std::size_t>(i) + 1]; ++k)
      if (kind[static_cast<std::size_t>(X.idx[static_cast<std::size_t>(k)])] == 0) ++beam_interior_entries;
  }
  if (nI > max_interface) {
    std::printf("{\"variant\": \"%s\", \"skipped\": \"interface too large\", \"dof_free\": %d, \"interior_solid\": %zu, "
                "\"interface\": %zu, \"beam\": %zu, \"dense_schur_mb\": %.0f, \"beam_interior_entries\": %zu}\n",
                variant.c_str(), X.NF, nE, nI, nB, static_cast<double>(nI) * static_cast<double>(nI) * 8.0 / 1048576.0,
                beam_interior_entries);
    return 0;
  }
  std::vector<int> emap(static_cast<std::size_t>(X.NF), -1), rmap(static_cast<std::size_t>(X.NF), -1);
  std::vector<int> ilist, blist;
  { int e = 0; for (int i = 0; i < X.NF; ++i) if (kind[static_cast<std::size_t>(i)] == 0) emap[static_cast<std::size_t>(i)] = e++; }
  { int r = 0;
    for (int i = 0; i < X.NF; ++i) if (kind[static_cast<std::size_t>(i)] == 1) { rmap[static_cast<std::size_t>(i)] = r++; ilist.push_back(i); }
    for (int i = 0; i < X.NF; ++i) if (kind[static_cast<std::size_t>(i)] == 2) { rmap[static_cast<std::size_t>(i)] = r++; blist.push_back(i); } }
  const int nR = static_cast<int>(nI + nB);
  Sub Kee = sub_csr(X, emap, static_cast<int>(nE));
  ResearchFactor Fee;
  const auto t1 = std::chrono::steady_clock::now();
  if (!Fee.factor(Kee.n, Kee.ptr, Kee.idx, Kee.val)) {
    std::printf("{\"variant\": \"%s\", \"error\": \"K_ee %s\"}\n", variant.c_str(), Fee.note.c_str()); return 1; }
  const double t_fee = std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count();
  // K_eI columns (per interface dof c: list of (e, val))
  std::vector<std::vector<std::pair<int, double>>> KeI(nI);
  for (int i = 0; i < X.NF; ++i) {
    if (kind[static_cast<std::size_t>(i)] != 0) continue;
    for (int k = X.ptr[static_cast<std::size_t>(i)]; k < X.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
      const int j = X.idx[static_cast<std::size_t>(k)];
      if (kind[static_cast<std::size_t>(j)] == 1) KeI[static_cast<std::size_t>(rmap[static_cast<std::size_t>(j)])].push_back({emap[static_cast<std::size_t>(i)], X.val[static_cast<std::size_t>(k)]});
    }
  }
  // S_II = K_II - K_Ie K_ee^-1 K_eI, column by column (Y_c never stored)
  const auto t2 = std::chrono::steady_clock::now();
  std::vector<double> S(nI * nI, 0.0);
  std::vector<double> y(static_cast<std::size_t>(nE));
  for (std::size_t c = 0; c < nI; ++c) {
    std::fill(y.begin(), y.end(), 0.0);
    for (const auto& e : KeI[c]) y[static_cast<std::size_t>(e.first)] = e.second;
    Fee.solve(y);
    for (std::size_t a = 0; a < nI; ++a) {
      double acc = 0.0;
      for (const auto& e : KeI[a]) acc += e.second * y[static_cast<std::size_t>(e.first)];
      S[a * nI + c] -= acc;
    }
  }
  const double t_schur = std::chrono::duration<double>(std::chrono::steady_clock::now() - t2).count();
  // F_r: F_I - K_Ie K_ee^-1 F_e
  std::vector<double> fe(static_cast<std::size_t>(nE));
  for (int i = 0; i < X.NF; ++i) if (kind[static_cast<std::size_t>(i)] == 0) fe[static_cast<std::size_t>(emap[static_cast<std::size_t>(i)])] = fs.Ff[static_cast<std::size_t>(i)];
  Fee.solve(fe);   // fe = K_ee^-1 F_e
  std::vector<double> Fr(static_cast<std::size_t>(nR), 0.0);
  for (int i = 0; i < X.NF; ++i) if (rmap[static_cast<std::size_t>(i)] >= 0) Fr[static_cast<std::size_t>(rmap[static_cast<std::size_t>(i)])] = fs.Ff[static_cast<std::size_t>(i)];
  for (std::size_t a = 0; a < nI; ++a) { double acc = 0; for (const auto& e : KeI[a]) acc += e.second * fe[static_cast<std::size_t>(e.first)]; Fr[a] -= acc; }
  // reduced CSR: K_rr (sparse, includes K_II) plus the dense correction on the II block
  Sub Krr = sub_csr(X, rmap, nR);
  std::vector<std::vector<std::pair<int, double>>> rows(static_cast<std::size_t>(nR));
  for (int a = 0; a < nR; ++a)
    for (int k = Krr.ptr[static_cast<std::size_t>(a)]; k < Krr.ptr[static_cast<std::size_t>(a) + 1]; ++k)
      rows[static_cast<std::size_t>(a)].push_back({Krr.idx[static_cast<std::size_t>(k)], Krr.val[static_cast<std::size_t>(k)]});
  for (std::size_t a = 0; a < nI; ++a)
    for (std::size_t c = 0; c < nI; ++c)
      if (S[a * nI + c] != 0.0) rows[a].push_back({static_cast<int>(c), S[a * nI + c]});
  std::vector<int> rptr(static_cast<std::size_t>(nR) + 1, 0), ridx; std::vector<double> rval;
  for (int a = 0; a < nR; ++a) {
    auto& rw = rows[static_cast<std::size_t>(a)];
    std::sort(rw.begin(), rw.end(), [](const auto& p, const auto& q) { return p.first < q.first; });
    // merge duplicates (sparse K_II entry + dense correction on the same column)
    std::vector<std::pair<int, double>> mg;
    for (const auto& e : rw) { if (!mg.empty() && mg.back().first == e.first) mg.back().second += e.second; else mg.push_back(e); }
    rptr[static_cast<std::size_t>(a) + 1] = rptr[static_cast<std::size_t>(a)] + static_cast<int>(mg.size());
    for (const auto& e : mg) { ridx.push_back(e.first); rval.push_back(e.second); }
  }
  const auto t3 = std::chrono::steady_clock::now();
  const ResearchDirectSolve rr = research_direct_solve(nR, rptr, ridx, rval, Fr);
  const double t_red = std::chrono::duration<double>(std::chrono::steady_clock::now() - t3).count();
  if (!rr.ok) { std::printf("{\"variant\": \"%s\", \"error\": \"reduced %s\"}\n", variant.c_str(), rr.note.c_str()); return 1; }
  // recover: u_e = K_ee^-1 (F_e - K_eI u_I)
  std::vector<double> ue(static_cast<std::size_t>(nE));
  for (int i = 0; i < X.NF; ++i) if (kind[static_cast<std::size_t>(i)] == 0) ue[static_cast<std::size_t>(emap[static_cast<std::size_t>(i)])] = fs.Ff[static_cast<std::size_t>(i)];
  for (std::size_t c = 0; c < nI; ++c) for (const auto& e : KeI[c]) ue[static_cast<std::size_t>(e.first)] -= e.second * rr.u[c];
  Fee.solve(ue);
  std::vector<double> ufree(static_cast<std::size_t>(X.NF), 0.0);
  for (int i = 0; i < X.NF; ++i) {
    if (kind[static_cast<std::size_t>(i)] == 0) ufree[static_cast<std::size_t>(i)] = ue[static_cast<std::size_t>(emap[static_cast<std::size_t>(i)])];
    else ufree[static_cast<std::size_t>(i)] = rr.u[static_cast<std::size_t>(rmap[static_cast<std::size_t>(i)])];
  }
  const std::vector<double> u = to_full(X, ufree);
  const std::vector<double> st = X.recover(u);
  const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  const ProcessMemory m1 = process_memory();
  const std::vector<char> nodrop;
  const Stat sm = statistic(net, st, nodrop, d.yield, d.zkd, d.build);
  Agreement ag; if (!ref_stress_path.empty()) ag = agree(read_stress(ref_stress_path), st);
  if (FILE* f = std::fopen((outp + ".stress").c_str(), "w")) { for (double v : st) std::fprintf(f, "%.9g\n", v); std::fclose(f); }
  std::printf("{\"variant\": \"%s\", \"members\": %zu, \"dof_free\": %d, \"interior_solid\": %zu, \"interface\": %zu, \"beam\": %zu, "
              "\"beam_interior_entries\": %zu, \"kee_factor_gb\": %.4f, \"kee_factor_s\": %.2f, \"schur_s\": %.2f, \"schur_dense_mb\": %.0f, "
              "\"reduced_dof\": %d, \"reduced_nnz\": %zu, \"reduced_factor_gb\": %.4f, \"reduced_solve_s\": %.2f, \"wall_s\": %.2f, "
              "\"rss_before_mb\": %.0f, \"rss_after_mb\": %.0f, \"peak_rss_mb\": %.0f, "
              "\"mem\": {\"n\": %zu, \"p99\": %.5g, \"max\": %.5g, \"margin\": %.4g, \"certified\": %s}, "
              "\"agree\": {\"n\": %zu, \"max_rel\": %.3g, \"over1pct\": %zu, \"over5pct\": %zu, \"p99_ref\": %.5g, \"p99_new\": %.5g}}\n",
              variant.c_str(), net.members.size(), X.NF, nE, nI, nB, beam_interior_entries, Fee.factor_gb, t_fee, t_schur,
              static_cast<double>(nI) * static_cast<double>(nI) * 8.0 / 1048576.0, nR, rval.size(), rr.factor_gb, t_red, wall,
              m0.rss_mb, m1.rss_mb, m1.peak_rss_mb, sm.n, sm.p99, sm.max, sm.margin, sm.certified ? "true" : "false",
              ag.n, ag.max_rel, ag.over1, ag.over5, ag.p99_ref, ag.p99_new);
  return 0;
}

// SUBMODEL: keep solid dofs within margin voxels of any beam node; prescribe the rest from the reference u.
static int run_submodel(const Dump& d, const BeamNetwork& net, const std::string& outp, const std::string& variant,
                        double margin_vox, const std::string& ref_u_path, const std::string& ref_stress_path) {
  const ProcessMemory m0 = process_memory();
  const auto t0 = std::chrono::steady_clock::now();
  FreeSys fs = export_system(d, net);
  const CoupledResearchExport& X = fs.X;
  // The reference may come from a DIFFERENT network on the same grid (the merged one,
  // a coarser global model): only its SOLID part [0, SB) is read, and that numbering is
  // shared. Every dropped dof is solid, so that is all the cut needs.
  std::vector<double> uref(static_cast<std::size_t>(X.M), 0.0);
  { FILE* f = std::fopen(ref_u_path.c_str(), "rb"); if (!f) { std::printf("{\"variant\": \"%s\", \"error\": \"no reference u\"}\n", variant.c_str()); return 1; }
    const std::size_t got = std::fread(uref.data(), sizeof(double), static_cast<std::size_t>(X.SB), f); std::fclose(f);
    if (got != static_cast<std::size_t>(X.SB)) { std::printf("{\"variant\": \"%s\", \"error\": \"reference u shorter than the solid block: %zu < %d\"}\n", variant.c_str(), got, X.SB); return 1; } }
  // solid nodes within margin of any beam node: hash beam nodes on a grid of cell = margin*h
  const double h = d.grid.spacing, R = margin_vox * h, cell = std::max(R, h);
  std::map<long long, std::vector<int>> hash;
  auto key = [&](double x, double y, double z) {
    const long long i = static_cast<long long>(std::floor(x / cell)), j = static_cast<long long>(std::floor(y / cell)), k = static_cast<long long>(std::floor(z / cell));
    return (i * 73856093LL) ^ (j * 19349663LL) ^ (k * 83492791LL); };
  for (std::size_t n = 0; n < net.nodes.size(); ++n) hash[key(net.nodes[n].x, net.nodes[n].y, net.nodes[n].z)].push_back(static_cast<int>(n));
  const std::size_t NS = X.solid_node_xyz.size() / 3;
  std::vector<char> keep_node(NS, 0);
  std::size_t kept_nodes = 0;
  for (std::size_t sn = 0; sn < NS; ++sn) {
    const double x = X.solid_node_xyz[3 * sn], y = X.solid_node_xyz[3 * sn + 1], z = X.solid_node_xyz[3 * sn + 2];
    bool near = false;
    for (int di = -1; di <= 1 && !near; ++di) for (int dj = -1; dj <= 1 && !near; ++dj) for (int dk = -1; dk <= 1 && !near; ++dk) {
      const auto it = hash.find(key(x + di * cell, y + dj * cell, z + dk * cell));
      if (it == hash.end()) continue;
      for (int bn : it->second) {
        const Vec3& q = net.nodes[static_cast<std::size_t>(bn)];
        const double dx = q.x - x, dy = q.y - y, dz = q.z - z;
        if (dx * dx + dy * dy + dz * dz <= R * R) { near = true; break; }
      }
    }
    if (near) { keep_node[sn] = 1; ++kept_nodes; }
  }
  std::vector<int> kmap(static_cast<std::size_t>(X.NF), -1);
  int nK = 0; std::size_t dropped = 0;
  for (int i = 0; i < X.NF; ++i) {
    const int full = X.from_free[static_cast<std::size_t>(i)];
    const bool keep = X.dof_is_beam[static_cast<std::size_t>(full)] || (full < X.SB && keep_node[static_cast<std::size_t>(full / 3)]);
    if (keep) kmap[static_cast<std::size_t>(i)] = nK++; else ++dropped;
  }
  Sub Kkk = sub_csr(X, kmap, nK);
  std::vector<double> Fk(static_cast<std::size_t>(nK), 0.0);
  std::size_t cut_dofs = 0;
  for (int i = 0; i < X.NF; ++i) {
    const int a = kmap[static_cast<std::size_t>(i)];
    if (a < 0) continue;
    double acc = fs.Ff[static_cast<std::size_t>(i)];
    bool touches_cut = false;
    for (int k = X.ptr[static_cast<std::size_t>(i)]; k < X.ptr[static_cast<std::size_t>(i) + 1]; ++k) {
      const int j = X.idx[static_cast<std::size_t>(k)];
      if (kmap[static_cast<std::size_t>(j)] >= 0) continue;
      acc -= X.val[static_cast<std::size_t>(k)] * uref[static_cast<std::size_t>(X.from_free[static_cast<std::size_t>(j)])];
      touches_cut = true;
    }
    if (touches_cut) ++cut_dofs;
    Fk[static_cast<std::size_t>(a)] = acc;
  }
  const auto t1 = std::chrono::steady_clock::now();
  const ResearchDirectSolve rr = research_direct_solve(nK, Kkk.ptr, Kkk.idx, Kkk.val, Fk);
  const double t_solve = std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count();
  if (!rr.ok) { std::printf("{\"variant\": \"%s\", \"error\": \"%s\"}\n", variant.c_str(), rr.note.c_str()); return 1; }
  std::vector<double> u = uref;
  for (int i = 0; i < X.NF; ++i) if (kmap[static_cast<std::size_t>(i)] >= 0) u[static_cast<std::size_t>(X.from_free[static_cast<std::size_t>(i)])] = rr.u[static_cast<std::size_t>(kmap[static_cast<std::size_t>(i)])];
  const std::vector<double> st = X.recover(u);
  const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  const ProcessMemory m1 = process_memory();
  const std::vector<char> nodrop;
  const Stat sm = statistic(net, st, nodrop, d.yield, d.zkd, d.build);
  Agreement ag; if (!ref_stress_path.empty()) ag = agree(read_stress(ref_stress_path), st);
  if (FILE* f = std::fopen((outp + ".stress").c_str(), "w")) { for (double v : st) std::fprintf(f, "%.9g\n", v); std::fclose(f); }
  std::printf("{\"variant\": \"%s\", \"margin_vox\": %.3g, \"members\": %zu, \"dof_free\": %d, \"kept_dof\": %d, \"dropped_dof\": %zu, "
              "\"kept_solid_nodes\": %zu, \"cut_dofs\": %zu, \"kept_nnz\": %zu, \"factor_gb\": %.4f, \"solve_s\": %.2f, \"wall_s\": %.2f, "
              "\"rss_before_mb\": %.0f, \"rss_after_mb\": %.0f, \"peak_rss_mb\": %.0f, "
              "\"mem\": {\"n\": %zu, \"p99\": %.5g, \"max\": %.5g, \"margin\": %.4g, \"certified\": %s}, "
              "\"agree\": {\"n\": %zu, \"max_rel\": %.3g, \"over1pct\": %zu, \"over5pct\": %zu, \"p99_ref\": %.5g, \"p99_new\": %.5g}}\n",
              variant.c_str(), margin_vox, net.members.size(), X.NF, nK, dropped, kept_nodes, cut_dofs, Kkk.val.size(), rr.factor_gb,
              t_solve, wall, m0.rss_mb, m1.rss_mb, m1.peak_rss_mb, sm.n, sm.p99, sm.max, sm.margin, sm.certified ? "true" : "false",
              ag.n, ag.max_rel, ag.over1, ag.over5, ag.p99_ref, ag.p99_new);
  return 0;
}


// ── SPAN OVERRIDE + THE RUN'S NODE MERGE (organic_lattice.cpp: endpoints within
// kOrganicNodeMergeRatio x min radius, snapped to the cluster centroid) ──
static std::vector<BeamSegment> read_spans_ledger(const std::string& path) {
  std::vector<BeamSegment> out; FILE* f = std::fopen(path.c_str(), "r"); if (!f) return out;
  char line[512];
  while (std::fgets(line, sizeof line, f)) {
    if (std::strncmp(line, "SEG ", 4) != 0) continue;
    BeamSegment s; int tag = 0;
    const int n = std::sscanf(line + 4, "%lf %lf %lf %lf %lf %lf %lf %d", &s.a.x, &s.a.y, &s.a.z, &s.b.x, &s.b.y, &s.b.z, &s.radius_mm, &tag);
    if (n < 7) continue;
    s.tag = n == 8 ? tag : 0;
    out.push_back(s);
  }
  std::fclose(f); return out;
}
static std::size_t merge_nodes_like_the_run(std::vector<BeamSegment>& spans, double ratio) {
  const std::size_t n = spans.size();
  std::vector<Vec3> ep(2 * n); std::vector<double> er(2 * n);
  for (std::size_t i = 0; i < n; ++i) { ep[2 * i] = spans[i].a; ep[2 * i + 1] = spans[i].b; er[2 * i] = er[2 * i + 1] = spans[i].radius_mm; }
  double rmax = 0; for (double r : er) rmax = std::max(rmax, r);
  const double cell = std::max(1e-6, ratio * rmax);
  std::map<std::array<long long, 3>, std::vector<int>> bins;
  auto key = [&](const Vec3& p) { return std::array<long long, 3>{static_cast<long long>(std::floor(p.x / cell)), static_cast<long long>(std::floor(p.y / cell)), static_cast<long long>(std::floor(p.z / cell))}; };
  for (std::size_t i = 0; i < ep.size(); ++i) bins[key(ep[i])].push_back(static_cast<int>(i));
  std::vector<int> par(ep.size()); for (std::size_t i = 0; i < par.size(); ++i) par[i] = static_cast<int>(i);
  std::function<int(int)> find = [&](int x) { while (par[static_cast<std::size_t>(x)] != x) { par[static_cast<std::size_t>(x)] = par[static_cast<std::size_t>(par[static_cast<std::size_t>(x)])]; x = par[static_cast<std::size_t>(x)]; } return x; };
  for (const auto& kv : bins)
    for (long long dz = -1; dz <= 1; ++dz) for (long long dy = -1; dy <= 1; ++dy) for (long long dx = -1; dx <= 1; ++dx) {
      auto it = bins.find({kv.first[0] + dx, kv.first[1] + dy, kv.first[2] + dz});
      if (it == bins.end()) continue;
      for (int i : kv.second) for (int j : it->second) {
        if (j <= i) continue;
        const double rr = ratio * std::min(er[static_cast<std::size_t>(i)], er[static_cast<std::size_t>(j)]);
        const Vec3& p = ep[static_cast<std::size_t>(i)]; const Vec3& q = ep[static_cast<std::size_t>(j)];
        const double dx2 = p.x - q.x, dy2 = p.y - q.y, dz2 = p.z - q.z;
        if (dx2 * dx2 + dy2 * dy2 + dz2 * dz2 > rr * rr) continue;
        const int a = find(i), b = find(j); if (a != b) par[static_cast<std::size_t>(std::max(a, b))] = std::min(a, b);
      }
    }
  std::map<int, std::vector<int>> cl; for (std::size_t i = 0; i < ep.size(); ++i) cl[find(static_cast<int>(i))].push_back(static_cast<int>(i));
  std::size_t merged = 0;
  for (const auto& kv : cl) {
    if (kv.second.size() < 2) continue;
    Vec3 c{0, 0, 0}; for (int i : kv.second) { c.x += ep[static_cast<std::size_t>(i)].x; c.y += ep[static_cast<std::size_t>(i)].y; c.z += ep[static_cast<std::size_t>(i)].z; }
    c.x /= kv.second.size(); c.y /= kv.second.size(); c.z /= kv.second.size();
    for (int i : kv.second) { ep[static_cast<std::size_t>(i)] = c; ++merged; }
  }
  for (std::size_t i = 0; i < n; ++i) { spans[i].a = ep[2 * i]; spans[i].b = ep[2 * i + 1]; }
  // drop spans collapsed to a point
  std::vector<BeamSegment> kept; kept.reserve(n);
  for (const BeamSegment& s : spans) { const double dx = s.b.x - s.a.x, dy = s.b.y - s.a.y, dz = s.b.z - s.a.z; if (dx * dx + dy * dy + dz * dz > 1e-12) kept.push_back(s); }
  spans.swap(kept);
  return merged;
}


// solidfactor: factor the interior solid alone (K_ee) -- the one-time cost an implicit
// condensation keeps; beamblock: factor the retained block K_rr (interface + beam)
// WITHOUT the Schur correction -- a size probe for the per-solve system, not a solve.
static int run_blocks(const Dump& d, const BeamNetwork& net, const std::string& variant) {
  const ProcessMemory m0 = process_memory();
  FreeSys fs = export_system(d, net);
  const CoupledResearchExport& X = fs.X;
  std::vector<char> is_iface(static_cast<std::size_t>(X.M), 0);
  for (int dd : X.tie_host_dofs) is_iface[static_cast<std::size_t>(dd)] = 1;
  std::vector<int> emap(static_cast<std::size_t>(X.NF), -1), rmap(static_cast<std::size_t>(X.NF), -1);
  int nE = 0, nR = 0, nI = 0;
  for (int i = 0; i < X.NF; ++i) {
    const int full = X.from_free[static_cast<std::size_t>(i)];
    if (X.dof_is_beam[static_cast<std::size_t>(full)]) rmap[static_cast<std::size_t>(i)] = nR++;
    else if (is_iface[static_cast<std::size_t>(full)]) { rmap[static_cast<std::size_t>(i)] = nR++; ++nI; }
    else emap[static_cast<std::size_t>(i)] = nE++;
  }
  const bool solid = variant == "solidfactor";
  Sub S = solid ? sub_csr(X, emap, nE) : sub_csr(X, rmap, nR);
  ResearchFactor F;
  const bool ok = F.factor(S.n, S.ptr, S.idx, S.val);
  const ProcessMemory m1 = process_memory();
  std::printf("{\"variant\": \"%s\", \"dof\": %d, \"nnz\": %zu, \"factor_gb\": %.4f, \"factor_s\": %.2f, \"ok\": %s, \"interface\": %d, "
              "\"rss_before_mb\": %.0f, \"rss_after_mb\": %.0f, \"peak_rss_mb\": %.0f}\n",
              variant.c_str(), S.n, S.val.size(), F.factor_gb, F.seconds, ok ? "true" : "false", nI, m0.rss_mb, m1.rss_mb, m1.peak_rss_mb);
  return ok ? 0 : 1;
}

int main(int argc, char** argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: cert_research <dump> <variant> [out_prefix]\n"); return 1; }
  const std::string variant = argv[2];
  const std::string outp = argc > 3 ? argv[3] : "cert_research";
  Dump d = load_dump(argv[1]);
  // options after the positional args: --spans <ledger>  --merge-nodes <ratio>
  for (int ai = 4; ai + 1 < argc; ++ai) {
    if (std::strcmp(argv[ai], "--spans") == 0) {
      d.spans = read_spans_ledger(argv[ai + 1]);
      std::fprintf(stderr, "[cert_research] spans overridden from %s: %zu\n", argv[ai + 1], d.spans.size());
    } else if (std::strcmp(argv[ai], "--reach") == 0) {
      d.reach = std::atof(argv[ai + 1]);
      std::fprintf(stderr, "[cert_research] load reach overridden: %g mm\n", d.reach);
    } else if (std::strcmp(argv[ai], "--merge-nodes") == 0) {
      const std::size_t before = d.spans.size();
      const std::size_t moved = merge_nodes_like_the_run(d.spans, std::atof(argv[ai + 1]));
      std::fprintf(stderr, "[cert_research] node merge x%s: %zu endpoints snapped, spans %zu -> %zu\n", argv[ai + 1], moved, before, d.spans.size());
    }
  }
  double deg = 15.0;
  if (variant.rfind("merge", 0) == 0 && variant.size() > 6) deg = std::atof(variant.c_str() + 6);

  std::vector<BeamSegment> spans = d.spans;
  Merged mg;
  const bool merged = variant.rfind("merge", 0) == 0 || variant.rfind("stats-merge", 0) == 0 || variant == "xbase-merge" || variant.rfind("submodel-merge", 0) == 0;
  if (merged) { mg = merge_chains(d.spans, variant.rfind("stats-merge", 0) == 0 && variant.size() > 12 ? std::atof(variant.c_str() + 12) : deg); spans = mg.spans; }

  const BeamNetwork net = build_beam_network(spans);
  // optional reference files for agreement: argv[4] = <ref>.u, argv[5] = <ref>.stress
  const std::string ref_u = (argc > 4 && std::strncmp(argv[4], "--", 2) != 0) ? argv[4] : "";
  const std::string ref_st = (argc > 5 && std::strncmp(argv[5], "--", 2) != 0) ? argv[5] : "";
  const BeamNetwork net_orig = merged ? build_beam_network(d.spans) : BeamNetwork{};
  if (merged) { g_merged = &mg; g_net0 = &net_orig; }
  if (variant == "xbase" || variant == "xbase-merge") return run_xbase(d, net, outp, variant);
  if (variant.rfind("submodel-merge", 0) == 0) {
    const double mv = variant.size() > 15 ? std::atof(variant.c_str() + 15) : 4.0;
    return run_submodel(d, net, outp, variant, mv, ref_u, ref_st);
  }
  if (variant == "solidfactor" || variant == "beamblock") return run_blocks(d, net, variant);
  if (variant.rfind("guyan", 0) == 0) {
    const std::size_t cap = variant.size() > 6 ? static_cast<std::size_t>(std::atof(variant.c_str() + 6)) : 6000;
    return run_guyan(d, net, outp, variant, cap, ref_st);
  }
  if (variant.rfind("submodel", 0) == 0) {
    const double mv = variant.size() > 9 ? std::atof(variant.c_str() + 9) : 4.0;
    return run_submodel(d, net, outp, variant, mv, ref_u, ref_st);
  }

  // ── stats / stats-merge: export the free system without solving ──
  if (variant.rfind("stats", 0) == 0) {
    CoupledResearchExport X;
    X.skip_solve = true;
    const ProcessMemory a0 = process_memory();
    (void)solve_coupled_lattice(d.grid, d.mask, net, d.cases[0].bcs, d.cases[0].loads, d.E, d.nu, 0.9, 1e-8, 100000,
                                nullptr, nullptr, d.reach, nullptr, nullptr, false, &X);
    const ProcessMemory a1 = process_memory();
    std::size_t nnz = X.val.size(), beam_free = 0;
    for (int i = 0; i < X.NF; ++i) beam_free += X.dof_is_beam[static_cast<std::size_t>(X.from_free[static_cast<std::size_t>(i)])] ? 1 : 0;
    std::printf("{\"variant\": \"%s\", \"members_before\": %zu, \"members\": %zu, \"beam_nodes\": %zu, \"beam_nodes_tied\": %zu, "
                "\"dof_full\": %d, \"dof_free\": %d, \"dof_solid\": %d, \"dof_beam_free\": %zu, \"nnz_full_symmetric\": %zu, "
                "\"interface_solid_dofs\": %zu, \"assembly_s\": %.2f, \"rss_before_mb\": %.0f, \"rss_after_mb\": %.0f}\n",
                variant.c_str(), merged ? mg.members_before : net.members.size(), net.members.size(), X.beam_nodes,
                X.beam_nodes_tied, X.M, X.NF, X.SB, beam_free, nnz, X.tie_host_dofs.size(), X.assembly_seconds, a0.rss_mb, a1.rss_mb);
    return 0;
  }
  const BeamNetwork net0 = build_beam_network(d.spans);   // the segment network, for the segment statistic

  // stage marks: dof, factor GB, times
  std::map<std::string, double> marks;
  SolveStage stage;
  stage.fn = [](const char* name, double seconds, double size, void* user) {
    auto* mk = static_cast<std::map<std::string, double>*>(user);
    (*mk)[name] = size;
    (*mk)[std::string(name) + ".s"] = seconds;
  };
  stage.user = &marks;

  const ProcessMemory m0 = process_memory();
  const auto t0 = std::chrono::steady_clock::now();
  const CoupledLatticeSolve r = solve_coupled_lattice(d.grid, d.mask, net, d.cases[0].bcs, d.cases[0].loads, d.E, d.nu,
                                                      0.9, 1e-8, 100000, nullptr, nullptr, d.reach, nullptr, &stage);
  const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  const ProcessMemory m1 = process_memory();

  // per-SEGMENT stresses: baseline = the members themselves; merge = each original
  // member takes its merged member's stress (the solve gives ONE stress per member --
  // the envelope over its ends -- so this is the conservative constant recovery, not
  // a linear one; stated in the report).
  std::vector<double> seg_stress(net0.members.size(), 0.0);
  std::vector<char> seg_dropped(net0.members.size(), 0);
  if (merged) {
    for (std::size_t j = 0; j < mg.origin_of.size() && j < r.member_stress_mpa.size(); ++j)
      for (int oi : mg.origin_of[j]) {
        seg_stress[static_cast<std::size_t>(oi)] = r.member_stress_mpa[j];
        if (j < r.member_dropped.size() && r.member_dropped[j]) seg_dropped[static_cast<std::size_t>(oi)] = 1;
      }
  } else {
    seg_stress = r.member_stress_mpa;
    for (std::size_t i = 0; i < r.member_dropped.size() && i < seg_dropped.size(); ++i) seg_dropped[i] = r.member_dropped[i];
  }
  const Stat s_seg = statistic(net0, seg_stress, seg_dropped, d.yield, d.zkd, d.build);
  const Stat s_mem = statistic(net, r.member_stress_mpa, r.member_dropped, d.yield, d.zkd, d.build);

  if (FILE* f = std::fopen((outp + ".stress").c_str(), "w")) {
    for (std::size_t i = 0; i < seg_stress.size(); ++i) std::fprintf(f, "%.9g\n", seg_stress[i]);
    std::fclose(f);
  }
  std::printf("{\"variant\": \"%s\", \"members_before\": %zu, \"members\": %zu, \"dof\": %.0f, \"factor_gb\": %.4f, "
              "\"wall_s\": %.2f, \"solve_converged\": %s, \"rss_before_mb\": %.0f, \"rss_after_mb\": %.0f, \"peak_rss_mb\": %.0f, "
              "\"load_dropped\": %.4g, "
              "\"seg\": {\"n\": %zu, \"p99\": %.5g, \"max\": %.5g, \"margin\": %.4g, \"certified\": %s}, "
              "\"mem\": {\"n\": %zu, \"p99\": %.5g, \"max\": %.5g, \"margin\": %.4g, \"certified\": %s}}\n",
              variant.c_str(), merged ? mg.members_before : net.members.size(), net.members.size(),
              marks["dof numbering"], marks["symbolic factorization"], wall, r.converged ? "true" : "false", m0.rss_mb,
              m1.rss_mb, m1.peak_rss_mb, r.load_dropped_fraction, s_seg.n, s_seg.p99, s_seg.max, s_seg.margin,
              s_seg.certified ? "true" : "false", s_mem.n, s_mem.p99, s_mem.max, s_mem.margin,
              s_mem.certified ? "true" : "false");
  return 0;
}
