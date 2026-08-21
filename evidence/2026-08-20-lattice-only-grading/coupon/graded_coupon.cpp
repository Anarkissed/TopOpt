// GRADED (FLOWING) LATTICE TEST COUPON — task 2026-08-20-lattice-only-grading §4(b).
//
// ★ THIS IS THE COUPON THAT TESTS THE THING IN DISPUTE. An earlier coupon swept the
// OCTET's horizontal struts, which is the STEPPED lattice — already printed, already
// known to work. The open question is whether the TRACED, FLOWING lattice is
// printable. This builds one, from the maintainer's OWN stress field.
//
// It is a COUPON, not a production path: §4(b) says do not build graded, and nothing
// here is wired into run_job. It exists to turn a scoping argument into a print.
//
// PIPELINE (the method §4(c) names):
//   job -> production_loadcase_from_job -> build_production_loadcase   [core's own]
//        -> analyze_fixed_design -> per-voxel stress tensor            [core's own]
//        -> cyclic-Jacobi eigen-decomposition                          [deterministic]
//        -> RK4 trace along a principal family
//        -> Jobard & Lefer 1997 spacing: accept a curve only where it stays at
//           least d_sep from every curve already placed
//        -> sweep each polyline segment as a capped n-gon prism + icosahedral nodes
//
// ★ THE SWEEP IS VERIFIED AGAINST PRODUCTION, not merely "the same idea". emit_strut
// and emit_node below are transcribed from core/src/mesh/lattice_gen.cpp (they are in
// its anonymous namespace, so they cannot be linked). `--selftest` generates ONE octet
// cell through core's `generate_lattice` and through these primitives and compares the
// triangle streams; it refuses to emit a coupon unless they are identical. Without
// that check "production geometry" would be a claim rather than a fact.
//
// Deterministic: fixed seed order, fixed traversal, no RNG.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/simp.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

Vec3 vsub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 vadd(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 vscale(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double vnorm(const Vec3& a) { return std::sqrt(a.x * a.x + a.y * a.y + a.z * a.z); }
Vec3 vunit(const Vec3& a) { const double n = vnorm(a); return {a.x / n, a.y / n, a.z / n}; }
Vec3 vcross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

// ── transcribed VERBATIM from core/src/mesh/lattice_gen.cpp (anonymous ns) ─────
void emit_strut(TriangleSink& sink, const Vec3& p0, const Vec3& p1, double r, int nseg) {
  const Vec3 axis = vunit(vsub(p1, p0));
  const Vec3 ref = std::fabs(axis.z) < 0.9 ? Vec3{0, 0, 1} : Vec3{1, 0, 0};
  const Vec3 u = vunit(vcross(axis, ref));
  const Vec3 v = vcross(axis, u);
  std::vector<Vec3> ring0(nseg), ring1(nseg);
  for (int i = 0; i < nseg; ++i) {
    const double a = 2.0 * M_PI * i / nseg;
    const Vec3 off = vadd(vscale(u, r * std::cos(a)), vscale(v, r * std::sin(a)));
    ring0[i] = vadd(p0, off);
    ring1[i] = vadd(p1, off);
  }
  for (int i = 0; i < nseg; ++i) {
    const int j = (i + 1) % nseg;
    sink.add_triangle(ring0[i], ring1[j], ring1[i]);
    sink.add_triangle(ring0[i], ring0[j], ring1[j]);
    sink.add_triangle(p0, ring0[j], ring0[i]);
    sink.add_triangle(p1, ring1[i], ring1[j]);
  }
}
void emit_node(TriangleSink& sink, const Vec3& c, double r) {
  const double t = (1.0 + std::sqrt(5.0)) / 2.0;
  const double s = r / std::sqrt(1.0 + t * t);
  std::array<Vec3, 12> p = {{{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0},
                             {0, -1, t}, {0, 1, t}, {0, -1, -t}, {0, 1, -t},
                             {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1}}};
  for (auto& q : p) q = vadd(c, vscale(q, s));
  static const int f[20][3] = {
      {0, 11, 5}, {0, 5, 1},   {0, 1, 7},   {0, 7, 10}, {0, 10, 11},
      {1, 5, 9},  {5, 11, 4},  {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
      {3, 9, 4},  {3, 4, 2},   {3, 2, 6},   {3, 6, 8},  {3, 8, 9},
      {4, 9, 5},  {2, 4, 11},  {6, 2, 10},  {8, 6, 7},  {9, 8, 1}};
  for (const auto& tr : f) sink.add_triangle(p[tr[0]], p[tr[1]], p[tr[2]]);
}

void jacobi3(const double A_in[6], double evec[3][3], double eval[3]) {
  double a[3][3] = {{A_in[0], A_in[3], A_in[5]},
                    {A_in[3], A_in[1], A_in[4]},
                    {A_in[5], A_in[4], A_in[2]}};
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) evec[i][j] = (i == j) ? 1.0 : 0.0;
  for (int sweep = 0; sweep < 24; ++sweep) {
    if (std::fabs(a[0][1]) + std::fabs(a[0][2]) + std::fabs(a[1][2]) < 1e-18) break;
    for (int p = 0; p < 2; ++p)
      for (int q = p + 1; q < 3; ++q) {
        if (std::fabs(a[p][q]) < 1e-20) continue;
        const double th = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
        const double t = (th >= 0 ? 1.0 : -1.0) / (std::fabs(th) + std::sqrt(th * th + 1.0));
        const double c = 1.0 / std::sqrt(t * t + 1.0), s = t * c;
        for (int k = 0; k < 3; ++k) { const double x = a[k][p], y = a[k][q];
          a[k][p] = c * x - s * y; a[k][q] = s * x + c * y; }
        for (int k = 0; k < 3; ++k) { const double x = a[p][k], y = a[q][k];
          a[p][k] = c * x - s * y; a[q][k] = s * x + c * y; }
        for (int k = 0; k < 3; ++k) { const double x = evec[k][p], y = evec[k][q];
          evec[k][p] = c * x - s * y; evec[k][q] = s * x + c * y; }
      }
  }
  for (int i = 0; i < 3; ++i) eval[i] = a[i][i];
}

struct TriCapture : TriangleSink {
  std::vector<Vec3> v;
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
    v.push_back(a); v.push_back(b); v.push_back(c);
  }
};

// ── the SELF-TEST: our transcribed primitives must reproduce production EXACTLY ──
// Generate one octet cell through core's `generate_lattice`, capturing BOTH its
// triangle stream AND, via the observer, the (kind, a, b, r) list of every solid it
// emitted. Re-emit that same list through OUR emit_strut / emit_node and compare the
// two triangle streams bit for bit. If they match, these primitives ARE production's.
bool selftest(std::string& why) {
  LatticeRegion region;
  region.origin = Vec3{0, 0, 0};
  region.nx = region.ny = region.nz = 1;
  region.cell_mm = 6.0;
  LatticeRadiusField rad; rad.uniform_mm = 0.55; rad.nseg = 8;

  TriCapture prod;
  struct El { LatticeGenElement k; Vec3 a, b; double r; };
  std::vector<El> els;
  LatticeGenObserver obs;
  obs.on_element = [&](LatticeGenElement k, const Vec3& a, const Vec3& b, double r) {
    els.push_back({k, a, b, r});
  };
  generate_lattice(LatticeGenTopology::Octet, region, rad, prod, LatticeSkinSpec{}, &obs);

  TriCapture mine;
  for (const El& e : els) {
    switch (e.k) {
      case LatticeGenElement::Node:
      case LatticeGenElement::AnchorNode:
        emit_node(mine, e.a, e.r); break;
      default:
        emit_strut(mine, e.a, e.b, e.r, rad.nseg); break;
    }
  }
  if (els.empty()) { why = "observer reported no elements"; return false; }
  if (prod.v.size() != mine.v.size()) {
    why = "triangle count differs: production " + std::to_string(prod.v.size() / 3) +
          " vs ours " + std::to_string(mine.v.size() / 3);
    return false;
  }
  for (std::size_t i = 0; i < prod.v.size(); ++i)
    if (std::memcmp(&prod.v[i], &mine.v[i], sizeof(Vec3)) != 0) {
      why = "vertex " + std::to_string(i) + " differs";
      return false;
    }
  why = std::to_string(els.size()) + " elements, " + std::to_string(prod.v.size() / 3) +
        " triangles, byte-identical";
  return true;
}

struct Poly { std::vector<Vec3> pts; };

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
      "usage: %s <job.json> <materials.json> [out.stl] [map.txt] [d_sep_mm] [strut_d_mm] [box_mm]\n",
      argv[0]);
    return 2;
  }
  const std::string job_path = argv[1], materials_path = argv[2];
  const std::string out = argc > 3 ? argv[3] : "graded_coupon.stl";
  const std::string mapp = argc > 4 ? argv[4] : "graded_coupon_MAP.txt";
  const double d_sep = argc > 5 ? std::atof(argv[5]) : 4.0;
  const double strut_d = argc > 6 ? std::atof(argv[6]) : 0.80;
  const double box_mm = argc > 7 ? std::atof(argv[7]) : 40.0;

  std::string why;
  std::printf("self-test (our sweep vs core's generate_lattice) ... ");
  if (!selftest(why)) { std::printf("FAILED: %s\n", why.c_str()); std::fprintf(stderr,
      "REFUSING: the transcribed primitives do not reproduce production geometry.\n"); return 3; }
  std::printf("ok — %s\n", why.c_str());

  const JobDescription job = load_job_file(job_path);
  const std::string dir = job_path.substr(0, job_path.find_last_of('/'));
  const StepModel model = import_part_file(dir + "/" + job.model);
  const MaterialLibrary lib = load_materials_file(materials_path);
  const auto mit = lib.find(job.material);
  if (mit == lib.end()) return 2;
  const Material mat = mit->second;

  const ProductionLoadCase lc = production_loadcase_from_job(job, model);
  ProductionRunSetup setup = build_production_loadcase(model, job.resolution, lc);
  const VoxelGrid& grid = setup.grid;
  std::vector<double> density(grid.voxel_count(), 0.0);
  std::size_t solid = 0;
  for (std::size_t i = 0; i < grid.tags.size(); ++i)
    if (grid.tags[i] != VoxelTag::Empty) { density[i] = 1.0; ++solid; }

  SimpParams sp; sp.youngs_modulus = mat.youngs_modulus_mpa; sp.poisson = mat.poisson;
  KnockdownSpec kd;
  const FixedDesignAnalysis a = analyze_fixed_design(
      grid, sp, density, setup.bcs, setup.options.external_loads, mat,
      Vec3{0, 0, 1}, 1e-8, 0, SolverKind::JacobiCG, 1.5, kd, true,
      static_cast<double>(solid));
  if (a.non_convergent || a.stress_tensor_field.size() != 6 * grid.voxel_count()) {
    std::fprintf(stderr, "REFUSING: no usable stress tensor.\n"); return 3; }
  double peak = 0.0;
  for (std::size_t e = 0; e < a.von_mises_field.size(); ++e)
    if (density[e] > 0.5 && a.von_mises_field[e] > peak) peak = a.von_mises_field[e];
  std::printf("load case reproduced: peak von Mises %.10g MPa\n", peak);

  // ALL THREE principal families. A single family is a set of disconnected
  // noodles: curves of one family never cross each other. A real flowing lattice
  // interlocks the three mutually-orthogonal families and ties them with
  // connectors, which is what makes it a BODY rather than loose strands.
  std::vector<std::array<float, 3>> dfam[3] = {
      std::vector<std::array<float, 3>>(grid.voxel_count(), {0, 0, 0}),
      std::vector<std::array<float, 3>>(grid.voxel_count(), {0, 0, 0}),
      std::vector<std::array<float, 3>>(grid.voxel_count(), {0, 0, 0})};
  for (std::size_t e = 0; e < grid.voxel_count(); ++e) {
    if (density[e] <= 0.5) continue;
    double A[6]; for (int c = 0; c < 6; ++c) A[c] = a.stress_tensor_field[6 * e + c];
    double V[3][3], w[3]; jacobi3(A, V, w);
    int idx[3] = {0, 1, 2};
    for (int i = 0; i < 3; ++i) for (int j = i + 1; j < 3; ++j)
      if (std::fabs(w[idx[j]]) > std::fabs(w[idx[i]])) std::swap(idx[i], idx[j]);
    for (int f = 0; f < 3; ++f)
      dfam[f][e] = {float(V[0][idx[f]]), float(V[1][idx[f]]), float(V[2][idx[f]])};
  }
  const std::vector<std::array<float, 3>>* active = &dfam[0];

  // ── the sub-box: a printable window centred on the part's solid centroid ──────
  Vec3 c{0, 0, 0}; double cnt = 0;
  for (int k = 0; k < grid.nz; ++k) for (int j = 0; j < grid.ny; ++j) for (int i = 0; i < grid.nx; ++i)
    if (density[grid.index(i, j, k)] > 0.5) {
      c = vadd(c, Vec3{grid.origin.x + (i + .5) * grid.spacing,
                       grid.origin.y + (j + .5) * grid.spacing,
                       grid.origin.z + (k + .5) * grid.spacing}); cnt += 1;
    }
  c = vscale(c, 1.0 / cnt);
  const double h = 0.5 * box_mm;
  const Vec3 blo{c.x - h, c.y - h, c.z - h}, bhi{c.x + h, c.y + h, c.z + h};
  std::printf("sub-box: %.1f mm cube centred at (%.1f, %.1f, %.1f)\n", box_mm, c.x, c.y, c.z);

  auto inbox = [&](const Vec3& p) {
    return p.x >= blo.x && p.x <= bhi.x && p.y >= blo.y && p.y <= bhi.y &&
           p.z >= blo.z && p.z <= bhi.z; };
  auto sample = [&](const Vec3& p, Vec3& d) -> bool {
    const int i = int((p.x - grid.origin.x) / grid.spacing);
    const int j = int((p.y - grid.origin.y) / grid.spacing);
    const int k = int((p.z - grid.origin.z) / grid.spacing);
    if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz) return false;
    const std::size_t e = grid.index(i, j, k);
    if (density[e] <= 0.5) return false;
    d = Vec3{(*active)[e][0], (*active)[e][1], (*active)[e][2]};
    if (!(vnorm(d) > 1e-12)) return false;
    d = vunit(d); return true; };

  // ── JOBARD & LEFER 1997: accept a curve only where it holds d_sep from the rest ─
  // Occupancy grid at d_sep resolution is the standard acceleration; a candidate
  // point is rejected when any already-accepted point lies within d_sep.
  const double cellg = d_sep;
  const int gx = std::max(1, int(box_mm / cellg) + 2), gy = gx, gz = gx;
  // ★ SEPARATION IS PER FAMILY. Applying d_sep across ALL curves also forces
  // curves of DIFFERENT families apart, so the three families can never come
  // within connector range and the result is loose strands (measured: 6
  // connectors, 75 components). Each family is thinned against ITSELF; families
  // are free to interleave and cross, which is what ties the lattice together.
  std::vector<std::vector<Vec3>> bins[3] = {
      std::vector<std::vector<Vec3>>(std::size_t(gx) * gy * gz),
      std::vector<std::vector<Vec3>>(std::size_t(gx) * gy * gz),
      std::vector<std::vector<Vec3>>(std::size_t(gx) * gy * gz)};
  int cur_fam = 0;
  auto bin_of = [&](const Vec3& p, int& i, int& j, int& k) {
    i = std::min(gx - 1, std::max(0, int((p.x - blo.x) / cellg)));
    j = std::min(gy - 1, std::max(0, int((p.y - blo.y) / cellg)));
    k = std::min(gz - 1, std::max(0, int((p.z - blo.z) / cellg))); };
  auto too_close = [&](const Vec3& p) {
    int i, j, k; bin_of(p, i, j, k);
    for (int dk = -1; dk <= 1; ++dk) for (int dj = -1; dj <= 1; ++dj) for (int di = -1; di <= 1; ++di) {
      const int ii = i + di, jj = j + dj, kk = k + dk;
      if (ii < 0 || jj < 0 || kk < 0 || ii >= gx || jj >= gy || kk >= gz) continue;
      for (const Vec3& q : bins[cur_fam][(std::size_t(kk) * gy + jj) * gx + ii])
        if (vnorm(vsub(p, q)) < d_sep) return true;
    }
    return false; };
  auto deposit = [&](const Vec3& p) {
    int i, j, k; bin_of(p, i, j, k);
    bins[cur_fam][(std::size_t(k) * gy + j) * gx + i].push_back(p); };

  const double step = grid.spacing * 0.5;
  std::vector<Poly> curves;
  std::vector<int> curve_fam;
  const int seed_stride = std::max(1, int(d_sep / grid.spacing));
  for (int fam = 0; fam < 3; ++fam) {
  active = &dfam[fam];
  cur_fam = fam;
  for (int k = 0; k < grid.nz; k += seed_stride)
   for (int j = 0; j < grid.ny; j += seed_stride)
    for (int i = 0; i < grid.nx; i += seed_stride) {
      const std::size_t e = grid.index(i, j, k);
      if (density[e] <= 0.5) continue;
      Vec3 s0{grid.origin.x + (i + .5) * grid.spacing,
              grid.origin.y + (j + .5) * grid.spacing,
              grid.origin.z + (k + .5) * grid.spacing};
      if (!inbox(s0) || too_close(s0)) continue;
      Poly fwd, bwd;
      for (int sgn = -1; sgn <= 1; sgn += 2) {
        Vec3 p = s0, prev{0, 0, 0}; bool hp = false;
        std::vector<Vec3>& acc = (sgn < 0 ? bwd.pts : fwd.pts);
        for (int s = 0; s < 4000; ++s) {
          Vec3 k1, k2, k3, k4;
          if (!sample(p, k1) || !inbox(p)) break;
          if (hp && (k1.x * prev.x + k1.y * prev.y + k1.z * prev.z) < 0) k1 = vscale(k1, -1);
          const double sd = sgn * step;
          if (!sample(vadd(p, vscale(k1, .5 * sd)), k2)) break;
          if ((k2.x*k1.x + k2.y*k1.y + k2.z*k1.z) < 0) k2 = vscale(k2, -1);
          if (!sample(vadd(p, vscale(k2, .5 * sd)), k3)) break;
          if ((k3.x*k1.x + k3.y*k1.y + k3.z*k1.z) < 0) k3 = vscale(k3, -1);
          if (!sample(vadd(p, vscale(k3, sd)), k4)) break;
          if ((k4.x*k1.x + k4.y*k1.y + k4.z*k1.z) < 0) k4 = vscale(k4, -1);
          Vec3 d{(k1.x + 2*k2.x + 2*k3.x + k4.x) / 6, (k1.y + 2*k2.y + 2*k3.y + k4.y) / 6,
                 (k1.z + 2*k2.z + 2*k3.z + k4.z) / 6};
          if (!(vnorm(d) > 1e-12)) break;
          d = vunit(d);
          const Vec3 np = vadd(p, vscale(d, sd));
          if (!inbox(np) || too_close(np)) break;
          acc.push_back(np); p = np; prev = d; hp = true;
        }
      }
      Poly cur;
      for (auto it = bwd.pts.rbegin(); it != bwd.pts.rend(); ++it) cur.pts.push_back(*it);
      cur.pts.push_back(s0);
      for (const Vec3& q : fwd.pts) cur.pts.push_back(q);
      if (cur.pts.size() < 3) continue;
      for (const Vec3& q : cur.pts) deposit(q);
      curves.push_back(std::move(cur));
      curve_fam.push_back(fam);
    }
  }


  // ── CONNECTORS + BASE ANCHORS, then a CONNECTIVITY CHECK ────────────────────
  // §4(c)'s "connect families by cross-product connectors": where points of two
  // DIFFERENT families come close, tie them with a strut. Without this the three
  // families interleave without touching and the object is loose strands.
  // Separately, every curve must reach the base slab or it starts in mid air.
  struct Node { Vec3 p; int curve; };
  std::vector<Node> pts;
  for (std::size_t ci = 0; ci < curves.size(); ++ci)
    for (const Vec3& q : curves[ci].pts) pts.push_back({q, int(ci)});

  const double conn_max = 1.10 * d_sep;   // tie only genuinely-near pairs
  std::vector<std::array<Vec3, 2>> connectors;
  {
    const double cg = conn_max;
    const int nx2 = std::max(1, int(box_mm / cg) + 2);
    std::vector<std::vector<int>> b2(std::size_t(nx2) * nx2 * nx2);
    auto bi = [&](const Vec3& q, int& i, int& j, int& k) {
      i = std::min(nx2 - 1, std::max(0, int((q.x - blo.x) / cg)));
      j = std::min(nx2 - 1, std::max(0, int((q.y - blo.y) / cg)));
      k = std::min(nx2 - 1, std::max(0, int((q.z - blo.z) / cg))); };
    for (std::size_t n = 0; n < pts.size(); ++n) {
      int i, j, k; bi(pts[n].p, i, j, k);
      b2[(std::size_t(k) * nx2 + j) * nx2 + i].push_back(int(n));
    }
    for (std::size_t n = 0; n < pts.size(); ++n) {
      int i, j, k; bi(pts[n].p, i, j, k);
      double best = 1e30; int bestn = -1;
      for (int dk = -1; dk <= 1; ++dk) for (int dj = -1; dj <= 1; ++dj) for (int di = -1; di <= 1; ++di) {
        const int ii = i + di, jj = j + dj, kk = k + dk;
        if (ii < 0 || jj < 0 || kk < 0 || ii >= nx2 || jj >= nx2 || kk >= nx2) continue;
        for (int m : b2[(std::size_t(kk) * nx2 + jj) * nx2 + ii]) {
          if (curve_fam[pts[m].curve] == curve_fam[pts[n].curve]) continue;
          const double dd = vnorm(vsub(pts[m].p, pts[n].p));
          if (dd > 1e-6 && dd < best && dd <= conn_max) { best = dd; bestn = m; }
        }
      }
      if (bestn >= 0 && bestn > int(n)) connectors.push_back({pts[n].p, pts[bestn].p});
    }
  }

  // BASE ANCHORS: drop a vertical leg from the lowest point of any curve whose
  // lowest point sits above the slab, so nothing begins in mid air.
  std::vector<std::array<Vec3, 2>> anchors;
  for (const Poly& cc : curves) {
    const Vec3* low = &cc.pts[0];
    for (const Vec3& q : cc.pts) if (q.z < low->z) low = &q;
    if (low->z > blo.z + 1e-6)
      anchors.push_back({*low, Vec3{low->x, low->y, blo.z}});
  }

  // CONNECTIVITY: union-find over curves via connectors; anything not reaching the
  // base through the graph is reported, because a coupon that fails for
  // disconnection tests nothing about flowing lattices.
  std::vector<int> uf(curves.size());
  for (std::size_t i = 0; i < uf.size(); ++i) uf[i] = int(i);
  std::function<int(int)> find = [&](int x) { while (uf[x] != x) { uf[x] = uf[uf[x]]; x = uf[x]; } return x; };
  auto uni = [&](int x, int y) { x = find(x); y = find(y); if (x != y) uf[x] = y; };
  {
    // map connector endpoints back to their curves via the point list
    for (const auto& cpair : connectors) {
      int ca = -1, cb = -1;
      for (const Node& nd : pts) {
        if (ca < 0 && vnorm(vsub(nd.p, cpair[0])) < 1e-9) ca = nd.curve;
        if (cb < 0 && vnorm(vsub(nd.p, cpair[1])) < 1e-9) cb = nd.curve;
        if (ca >= 0 && cb >= 0) break;
      }
      if (ca >= 0 && cb >= 0) uni(ca, cb);
    }
  }
  std::vector<int> comp;
  for (std::size_t i = 0; i < curves.size(); ++i) comp.push_back(find(int(i)));
  std::sort(comp.begin(), comp.end());
  comp.erase(std::unique(comp.begin(), comp.end()), comp.end());
  std::printf("connectors %zu   base anchors %zu   connected components %zu\n",
              connectors.size(), anchors.size(), comp.size());

  // ── the UNSUPPORTED-RUN statistic: contiguous arc beyond 45 deg from vertical ──
  // An UPPER BOUND: it ignores support a crossing curve may provide from below.
  std::vector<double> runs;
  double total_len = 0, flat_len = 0;
  for (const Poly& c2 : curves) {
    double run = 0;
    for (std::size_t i = 1; i < c2.pts.size(); ++i) {
      const Vec3 d = vsub(c2.pts[i], c2.pts[i - 1]);
      const double L = vnorm(d); if (!(L > 1e-12)) continue;
      total_len += L;
      if (std::fabs(d.z) / L < std::sqrt(0.5)) { run += L; flat_len += L; }
      else if (run > 0) { runs.push_back(run); run = 0; }
    }
    if (run > 0) runs.push_back(run);
  }
  std::sort(runs.begin(), runs.end());

  // ── COLLECT every solid first, so connectivity can be CHECKED and REPAIRED
  //    before a single triangle is written ─────────────────────────────────────
  struct Solid { Vec3 a, b; double r; };   // a == b means a ball
  std::vector<Solid> solids;
  const double r = 0.5 * strut_d;
  const double base_t = 1.2;
  const Vec3 shift{-blo.x, -blo.y, -blo.z + base_t};
  for (const Poly& c2 : curves) {
    for (std::size_t i = 1; i < c2.pts.size(); ++i) {
      const Vec3 p0 = vadd(c2.pts[i - 1], shift), p1 = vadd(c2.pts[i], shift);
      if (vnorm(vsub(p1, p0)) > 1e-9) solids.push_back({p0, p1, r});
    }
    for (const Vec3& q : c2.pts) { const Vec3 p0 = vadd(q, shift); solids.push_back({p0, p0, r}); }
  }
  for (const auto& cp : connectors) {
    const Vec3 p0 = vadd(cp[0], shift), p1 = vadd(cp[1], shift);
    if (vnorm(vsub(p1, p0)) > 1e-9) solids.push_back({p0, p1, r});
  }
  // ★ ANCHORS MUST PENETRATE THE SLAB, NOT KISS IT. The first version ended each
  // anchor at z = base_t, exactly the slab's top surface: a zero-thickness contact,
  // which is NOT a solid union and which a slicer correctly reports as a separate
  // floating body. They now run to z = 0.
  for (const auto& ap : anchors) {
    const Vec3 p0 = vadd(ap[0], shift);
    solids.push_back({p0, Vec3{p0.x, p0.y, 0.0}, r});
  }

  // ── RASTERISED CONNECTIVITY: the check a slicer effectively performs ────────
  // Voxelise every solid, 6-connected label from the slab, and report anything the
  // flood never reaches. Curve-level bookkeeping cannot see a zero-overlap contact;
  // this can.
  // ★ THE RASTER MUST BE CONSERVATIVE AND MUST MATCH THE EMITTED SOLID.
  // A first version tested distance-to-SEGMENT <= r, i.e. a CAPSULE. emit_strut
  // emits a FLAT-CAPPED n-gon PRISM, so the capsule's rounded ends reach r beyond
  // the real endpoint and BRIDGE a zero-overlap contact that is not there. Measured:
  // that version reported 0 floating voxels on geometry with the anchor defect
  // deliberately reintroduced — a false negative on the exact bug it existed to
  // catch. So: no cap extension (t is clamped to [0,1] and points outside are
  // rejected), and the radius used is the n-gon's INRADIUS, not its circumradius,
  // so the raster UNDER-states material. If a conservative raster says connected,
  // it is connected.
  const double kPrismInradius = std::cos(M_PI / 8.0);   // nseg = 8
  const double kIcosaInradius = 0.7946544722917661;     // icosahedron in/circum
  const double vx = 0.15;
  const int RX = int(box_mm / vx) + 4, RY = RX, RZ = int((box_mm + base_t) / vx) + 6;
  const Vec3 rlo{-2 * vx, -2 * vx, -2 * vx};
  auto ridx = [&](int i, int j, int k) { return (std::size_t(k) * RY + j) * RX + i; };
  std::vector<unsigned char> occ(std::size_t(RX) * RY * RZ, 0);
  auto stamp = [&](const Solid& sd) {
    const bool ball = vnorm(vsub(sd.b, sd.a)) < 1e-9;
    const double rr = sd.r * (ball ? kIcosaInradius : kPrismInradius);
    const double pad = sd.r;
    const Vec3 lo2{std::min(sd.a.x, sd.b.x) - pad, std::min(sd.a.y, sd.b.y) - pad,
                   std::min(sd.a.z, sd.b.z) - pad};
    const Vec3 hi2{std::max(sd.a.x, sd.b.x) + pad, std::max(sd.a.y, sd.b.y) + pad,
                   std::max(sd.a.z, sd.b.z) + pad};
    const int i0 = std::max(0, int((lo2.x - rlo.x) / vx)), i1 = std::min(RX - 1, int((hi2.x - rlo.x) / vx) + 1);
    const int j0 = std::max(0, int((lo2.y - rlo.y) / vx)), j1 = std::min(RY - 1, int((hi2.y - rlo.y) / vx) + 1);
    const int k0 = std::max(0, int((lo2.z - rlo.z) / vx)), k1 = std::min(RZ - 1, int((hi2.z - rlo.z) / vx) + 1);
    const Vec3 ab = vsub(sd.b, sd.a);
    const double L2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z;
    for (int k = k0; k <= k1; ++k) for (int j = j0; j <= j1; ++j) for (int i = i0; i <= i1; ++i) {
      const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
      if (ball) { if (vnorm(vsub(q, sd.a)) <= rr) occ[ridx(i, j, k)] = 1; continue; }
      const Vec3 aq = vsub(q, sd.a);
      const double t = (aq.x * ab.x + aq.y * ab.y + aq.z * ab.z) / L2;
      if (t < 0.0 || t > 1.0) continue;              // ★ FLAT caps: no extension
      const Vec3 c3{sd.a.x + ab.x * t, sd.a.y + ab.y * t, sd.a.z + ab.z * t};
      if (vnorm(vsub(q, c3)) <= rr) occ[ridx(i, j, k)] = 1;
    }
  };
  for (const Solid& sd : solids) stamp(sd);
  // the slab
  for (int k = 0; k < RZ; ++k) for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
    const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
    if (q.z >= 0 && q.z <= base_t && q.x >= 0 && q.x <= box_mm && q.y >= 0 && q.y <= box_mm)
      occ[ridx(i, j, k)] = 1;
  }

  auto flood_from_slab = [&](std::vector<unsigned char>& seen) {
    seen.assign(occ.size(), 0);
    std::vector<int> stack;
    for (int k = 0; k < RZ; ++k) for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
      const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
      if (occ[ridx(i, j, k)] && q.z >= 0 && q.z <= base_t) {
        if (!seen[ridx(i, j, k)]) { seen[ridx(i, j, k)] = 1; stack.push_back(int(ridx(i, j, k))); }
      }
    }
    while (!stack.empty()) {
      const int n = stack.back(); stack.pop_back();
      const int i = n % RX, j = (n / RX) % RY, k = n / (RX * RY);
      const int di[6] = {1,-1,0,0,0,0}, dj[6] = {0,0,1,-1,0,0}, dk[6] = {0,0,0,0,1,-1};
      for (int d = 0; d < 6; ++d) {
        const int ii = i + di[d], jj = j + dj[d], kk = k + dk[d];
        if (ii < 0 || jj < 0 || kk < 0 || ii >= RX || jj >= RY || kk >= RZ) continue;
        const std::size_t m = ridx(ii, jj, kk);
        if (occ[m] && !seen[m]) { seen[m] = 1; stack.push_back(int(m)); }
      }
    }
  };

  std::vector<unsigned char> seen;
  long long floating0 = 0;
  flood_from_slab(seen);
  for (std::size_t n = 0; n < occ.size(); ++n) if (occ[n] && !seen[n]) ++floating0;
  std::printf("connectivity: raster %dx%dx%d @ %.2f mm  floating voxels BEFORE repair: %lld\n",
              RX, RY, RZ, vx, floating0);

  // ── REPAIR: tie each floating component to the ground with a vertical leg,
  //    then re-flood. Repeat until nothing floats or no progress is made. ───────
  int repair_rounds = 0; long long added = 0;
  for (; repair_rounds < 12; ++repair_rounds) {
    long long fl = 0;
    for (std::size_t n = 0; n < occ.size(); ++n) if (occ[n] && !seen[n]) ++fl;
    if (fl == 0) break;
    // label floating components and drop a leg from each one's LOWEST voxel
    std::vector<unsigned char> done(occ.size(), 0);
    std::vector<Solid> legs;
    for (int k = 0; k < RZ; ++k) for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
      const std::size_t s0 = ridx(i, j, k);
      if (!occ[s0] || seen[s0] || done[s0]) continue;
      std::vector<int> st{int(s0)}; done[s0] = 1;
      int lowk = k, lowi = i, lowj = j;
      while (!st.empty()) {
        const int n = st.back(); st.pop_back();
        const int ii0 = n % RX, jj0 = (n / RX) % RY, kk0 = n / (RX * RY);
        if (kk0 < lowk) { lowk = kk0; lowi = ii0; lowj = jj0; }
        const int di[6] = {1,-1,0,0,0,0}, dj[6] = {0,0,1,-1,0,0}, dk[6] = {0,0,0,0,1,-1};
        for (int d = 0; d < 6; ++d) {
          const int ii = ii0 + di[d], jj = jj0 + dj[d], kk = kk0 + dk[d];
          if (ii < 0 || jj < 0 || kk < 0 || ii >= RX || jj >= RY || kk >= RZ) continue;
          const std::size_t m = ridx(ii, jj, kk);
          if (occ[m] && !seen[m] && !done[m]) { done[m] = 1; st.push_back(int(m)); }
        }
      }
      const Vec3 top{rlo.x + (lowi + .5) * vx, rlo.y + (lowj + .5) * vx, rlo.z + (lowk + .5) * vx};
      legs.push_back({top, Vec3{top.x, top.y, 0.0}, r});
    }
    if (legs.empty()) break;
    for (const Solid& L : legs) { solids.push_back(L); stamp(L); ++added; }
    flood_from_slab(seen);
  }
  long long floating1 = 0;
  for (std::size_t n = 0; n < occ.size(); ++n) if (occ[n] && !seen[n]) ++floating1;
  std::printf("repair: %lld legs added over %d rounds  floating voxels AFTER: %lld  %s\n",
              added, repair_rounds, floating1,
              floating1 == 0 ? "-> ONE CONNECTED BODY" : "-> STILL FLOATING");
  if (floating1 != 0) {
    std::fprintf(stderr, "REFUSING: %lld voxels still float; a coupon that fails for\n"
                         "disconnection tests nothing about flowing lattices.\n", floating1);
    return 3;
  }

  // ── mesh it ─────────────────────────────────────────────────────────────────
  MeshSink sink;
  {
    const Vec3 lo{0, 0, 0}, hi{box_mm, box_mm, base_t};
    const Vec3 p[8] = {{lo.x,lo.y,lo.z},{hi.x,lo.y,lo.z},{hi.x,hi.y,lo.z},{lo.x,hi.y,lo.z},
                       {lo.x,lo.y,hi.z},{hi.x,lo.y,hi.z},{hi.x,hi.y,hi.z},{lo.x,hi.y,hi.z}};
    const int f[12][3] = {{0,2,1},{0,3,2},{4,5,6},{4,6,7},{0,1,5},{0,5,4},
                          {1,2,6},{1,6,5},{2,3,7},{2,7,6},{3,0,4},{3,4,7}};
    for (const auto& t : f) sink.add_triangle(p[t[0]], p[t[1]], p[t[2]]);
  }
  std::uint64_t nseg_emitted = 0;
  for (const Solid& sd : solids) {
    if (vnorm(vsub(sd.b, sd.a)) < 1e-9) emit_node(sink, sd.a, sd.r);
    else { emit_strut(sink, sd.a, sd.b, sd.r, 8); ++nseg_emitted; }
  }
  write_stl_file(out, sink.mesh);

  // ── ★ THE WELDED, SINGLE-BODY VERSION ───────────────────────────────────────
  // The soup above is exactly how the shipped generator emits a lattice: each
  // strut is its own closed prism and each node its own icosahedron, interpene-
  // trating. Measured on this coupon: 2,725 separate closed shells. A slicer that
  // analyses the MESH rather than the unioned solid reports those as separate
  // bodies and flags the ones that do not touch the plate as FLOATING — which is
  // what happened. The material is genuinely connected (the conservative raster
  // above finds 0 floating voxels); the MESH is not one object.
  //
  // So a second file is written: marching cubes over the SAME occupancy raster the
  // connectivity check used, which yields ONE watertight body with no shells to
  // mis-report. The strut layout, diameters and spacing are unchanged; only the
  // surface tessellation differs (it is faceted at the raster pitch).
  {
    std::vector<double> field(occ.size());
    for (std::size_t n2 = 0; n2 < occ.size(); ++n2) field[n2] = occ[n2] ? 1.0 : 0.0;
    TriangleMesh welded = marching_cubes(RX, RY, RZ, vx, rlo, field, 0.5);
    const int comps_raw = count_components(welded);
    // The extra components are SEALED CAVITIES — air pockets fully enclosed where
    // struts cross — each of which marching cubes closes with its own inner
    // surface. Measured here: 6 of them, 8 to 328 triangles, against an outer
    // surface of 1,451,500. They are not floating material and not a print
    // problem, but they leave the mesh multi-component, which is precisely what a
    // slicer mis-reports. Dropping them fills the pockets solid.
    // (They are also a REAL finding for graded: a traced lattice seals voids, which
    // is a drainability question this codebase already tracks.)
    const std::size_t before_tris = welded.triangles.size();
    welded = keep_largest_component(welded);
    const int comps2 = count_components(welded);
    const WatertightReport wt = check_watertight(welded);
    const std::string wout = out.substr(0, out.find_last_of('.')) + "_WELDED.stl";
    write_stl_file(wout, welded);
    std::printf("welded body: %zu tris (was %zu, %d comps -> %d), watertight=%s\n"
                "             sealed cavities filled: %d\n             -> %s\n",
                welded.triangles.size(), before_tris, comps_raw, comps2,
                wt.watertight ? "YES" : "no", comps_raw - 1, wout.c_str());
  }

  std::FILE* mf = std::fopen(mapp.c_str(), "w");
  std::fprintf(mf,
    "GRADED (FLOWING) LATTICE COUPON — traced from the maintainer's own stress field\n"
    "================================================================================\n"
    "job              : %s\n  peak von Mises : %.10g MPa (reproduces the production analyze run)\n"
    "sub-box          : %.1f mm cube at part centroid (%.1f, %.1f, %.1f)\n"
    "spacing d_sep    : %.2f mm   (Jobard & Lefer 1997 streamline placement)\n"
    "strut diameter   : %.2f mm\n"
    "curves placed    : %zu  (all three principal families)\n"
    "  connectors      : %zu\n  base anchors    : %zu\n  repair legs     : %lld\n"
    "  FLOATING VOXELS : %lld  (rasterised check, 0 = one connected body)\n"
    "  segments        : %llu\n  triangles       : %zu\n\n"
    "TRACED ARC LENGTH\n  total            : %.1f mm\n"
    "  beyond 45 deg    : %.1f mm  (%.1f %%)\n\n"
    "UNSUPPORTED HORIZONTAL RUNS  (contiguous arc beyond 45 deg)\n"
    "  ★ UPPER BOUND: ignores support a crossing curve may give from below.\n"
    "  count            : %zu\n",
    job_path.c_str(), peak, box_mm, c.x, c.y, c.z, d_sep, strut_d,
    curves.size(), connectors.size(), anchors.size(), added, floating1,
    (unsigned long long)nseg_emitted, sink.mesh.triangles.size(),
    total_len, flat_len, 100.0 * flat_len / std::max(1e-9, total_len), runs.size());
  if (!runs.empty()) {
    auto q = [&](double f) { return runs[std::size_t(f * (runs.size() - 1))]; };
    std::fprintf(mf,
      "  median run       : %.2f mm\n  p90 run          : %.2f mm\n"
      "  p99 run          : %.2f mm\n  LONGEST run      : %.2f mm\n",
      q(.5), q(.9), q(.99), runs.back());
  }
  std::fprintf(mf,
    "\nWHAT TO LOOK FOR ON THE PLATE\n"
    "  Print with SUPPORTS OFF. The question is whether the flowing curves bridge.\n"
    "  The longest unsupported run above is the worst case the geometry contains;\n"
    "  compare it against the span the octet coupon shows is safe at this diameter.\n"
    "  Score: did every curve complete, where did any sag, and does the part hold\n"
    "  together as one body.\n");
  std::fclose(mf);

  std::printf("curves %zu   segments %llu   triangles %zu\n",
              curves.size(), (unsigned long long)nseg_emitted, sink.mesh.triangles.size());
  std::printf("traced arc: %.1f mm total, %.1f mm (%.1f %%) beyond 45 deg\n",
              total_len, flat_len, 100.0 * flat_len / std::max(1e-9, total_len));
  if (!runs.empty())
    std::printf("unsupported runs: median %.2f  p90 %.2f  LONGEST %.2f mm\n",
                runs[runs.size()/2], runs[std::size_t(.9*(runs.size()-1))], runs.back());
  std::printf("wrote %s\n       %s\n", out.c_str(), mapp.c_str());
  return 0;
}
