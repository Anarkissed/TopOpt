// GRADED (FLOWING) LATTICE COUPON, v2 — the maintainer's "ultimate goal" recipe with
// the two things the printed coupon taught: (1) d_sep is a FIELD mapped from the von
// Mises magnitude (small cells where stress is high — Curvy's formulation), with the
// strut thickness graded alongside; (2) HIS PRINTED RULE — "a bridge requires two
// bases to connect to at *all* times; you cannot create a bridge with only *one*
// leg" — enforced: one-legged shallow tails are TRIMMED back to their last supported
// crossing, and a census reports every shallow run's leg count. v1 is untouched and
// still reproduces the printed artifact byte-for-byte.
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
#include <fstream>
#include <functional>
#include <map>
#include <unordered_map>
#include <set>
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
// ★ THE FLAT-BOTTOMED TIE (the maintainer's own fix, from his layer sweep): a LEVEL
// tie emitted as a CYLINDER builds its round underside as a sliver line over air and
// then overhangs itself sideways, layer after layer — the stepped blue ledges his
// slice showed. A rectangular section has no such underside: its bottom face is one
// full-width flat ribbon, laid in a single pass, anchored at both ends, and every
// layer above rests fully on the one below. Square section 2r x 2r keeps the tie's
// mass equal to the round strut it replaces (within 27 %), and its ends bury inside
// the node balls exactly as the cylinder's did.
void emit_box_tie(TriangleSink& sink, const Vec3& a, const Vec3& b, double r) {
  Vec3 u = vsub(b, a);
  const double L = vnorm(u);
  if (!(L > 1e-9)) return;
  u = vscale(u, 1.0 / L);
  const Vec3 w{0, 0, 1};                       // level ties: vertical is exact
  Vec3 v{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
  const double vl = vnorm(v);
  if (!(vl > 1e-9)) return;                    // degenerate (vertical) — not a tie
  v = vscale(v, 1.0 / vl);
  const Vec3 vv = vscale(v, r), ww = vscale(w, r);
  const Vec3 p[8] = {
      vsub(vsub(a, vv), ww), vsub(vadd(a, vv), ww),
      vadd(vadd(a, vv), ww), vadd(vsub(a, vv), ww),
      vsub(vsub(b, vv), ww), vsub(vadd(b, vv), ww),
      vadd(vadd(b, vv), ww), vadd(vsub(b, vv), ww)};
  const int f[12][3] = {{0,1,2},{0,2,3},{4,6,5},{4,7,6},{0,4,5},{0,5,1},
                        {1,5,6},{1,6,2},{2,6,7},{2,7,3},{3,7,4},{3,4,0}};
  for (const auto& t : f) sink.add_triangle(p[t[0]], p[t[1]], p[t[2]]);
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

// ── DECLARED LATTICE REGIONS ────────────────────────────────────────────────
// A face region is a prism: the CAD face's plane at `origin` with unit `normal`,
// swept `depth` INTO the part, clipped in-plane to that face's real outline. The
// in-plane basis is built EXACTLY as core builds it (clearance.cpp plane_basis) —
// otherwise the region carved here is not the region the app declared.
struct FaceRegion {
  Vec3 origin, normal, u, w;
  double half_u = 0, half_w = 0, depth = 0;
  std::vector<std::vector<std::array<double, 2>>> loops;   // empty = plain rectangle
  bool include = true;
};

static bool plane_basis_like_core(const Vec3& n, Vec3& u, Vec3& w) {
  const Vec3 ref = std::fabs(n.x) < 0.9 ? Vec3{1, 0, 0} : Vec3{0, 1, 0};
  const Vec3 uu{ref.y * n.z - ref.z * n.y, ref.z * n.x - ref.x * n.z,
                ref.x * n.y - ref.y * n.x};
  const double ul = vnorm(uu);
  if (ul <= 1e-12) return false;
  u = vscale(uu, 1.0 / ul);
  w = Vec3{n.y * u.z - n.z * u.y, n.z * u.x - n.x * u.z, n.x * u.y - n.y * u.x};
  return true;
}

// Even-odd crossing test on the face's own (u, w) outline.
static bool point_in_loops(
    const std::vector<std::vector<std::array<double, 2>>>& loops, double du, double dw) {
  bool in = false;
  for (const auto& lp : loops) {
    const std::size_t n = lp.size();
    if (n < 3) continue;
    for (std::size_t i = 0, j = n - 1; i < n; j = i++) {
      const double xi = lp[i][0], yi = lp[i][1], xj = lp[j][0], yj = lp[j][1];
      if (((yi > dw) != (yj > dw)) &&
          (du < (xj - xi) * (dw - yi) / (yj - yi) + xi))
        in = !in;
    }
  }
  return in;
}

static bool region_contains_point(const FaceRegion& r, const Vec3& p) {
  const Vec3 rel = vsub(p, r.origin);
  const double sd = rel.x * r.normal.x + rel.y * r.normal.y + rel.z * r.normal.z;
  if (sd < 0.0 || sd > r.depth) return false;
  const double du = rel.x * r.u.x + rel.y * r.u.y + rel.z * r.u.z;
  const double dw = rel.x * r.w.x + rel.y * r.w.y + rel.z * r.w.z;
  if (du < -r.half_u || du > r.half_u || dw < -r.half_w || dw > r.half_w) return false;
  if (r.loops.empty()) return true;              // no outline exported: the rectangle
  return point_in_loops(r.loops, du, dw);
}

static std::vector<FaceRegion> load_regions(const std::string& path) {
  std::vector<FaceRegion> out;
  if (path.empty()) return out;
  std::ifstream in(path);
  if (!in) throw std::runtime_error("cannot open regions file: " + path);
  int nreg = 0; in >> nreg;
  for (int r = 0; r < nreg; ++r) {
    FaceRegion fr; int nloops = 0; std::string role;
    in >> fr.origin.x >> fr.origin.y >> fr.origin.z
       >> fr.normal.x >> fr.normal.y >> fr.normal.z
       >> fr.half_u >> fr.half_w >> fr.depth >> nloops >> role;
    if (!in) throw std::runtime_error("regions file: truncated header");
    fr.include = (role != "exclude");
    const double nl = vnorm(fr.normal);
    if (nl <= 1e-12) throw std::runtime_error("regions file: degenerate normal");
    fr.normal = vscale(fr.normal, 1.0 / nl);
    if (!plane_basis_like_core(fr.normal, fr.u, fr.w))
      throw std::runtime_error("regions file: cannot build a plane basis");
    for (int l = 0; l < nloops; ++l) {
      int np = 0; in >> np;
      std::vector<std::array<double, 2>> lp(std::size_t(std::max(0, np)));
      for (int q = 0; q < np; ++q) in >> lp[std::size_t(q)][0] >> lp[std::size_t(q)][1];
      fr.loops.push_back(std::move(lp));
    }
    if (!in) throw std::runtime_error("regions file: truncated outline");
    out.push_back(std::move(fr));
  }
  return out;
}

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
      "usage: %s <job.json> <materials.json> [out.stl] [map.txt] [d_min_mm] [d_max_mm] [strut_d_mm] [box_mm] [shape_band_mm] [swirl] [bead_pow] [enforce_print] [autoscale] [cell_pow] [strut_pow] [anchor_to_material] [regions.txt] [emit_welded] [rim_mm] [emit_solid] [solid_from_cad] [min_curve_cells] [d_test_ratio] [prune_rounds] [field_floor] [synth_lambda] [synth_foci] [synth_soft] [enforce_min_run_mm] [enforce_support_aware] [lean_deg] [fam0_sep_mult] [beam.out]\n",
      argv[0]);
    return 2;
  }
  const std::string job_path = argv[1], materials_path = argv[2];
  const std::string out = argc > 3 ? argv[3] : "graded_coupon.stl";
  const std::string mapp = argc > 4 ? argv[4] : "graded_coupon_MAP.txt";
  // v2: d_min:d_max graded window (equal values = uniform, v1 behaviour)
  const double d_min_in = argc > 5 ? std::atof(argv[5]) : 3.0;
  const double d_max_in = argc > 6 ? std::atof(argv[6]) : d_min_in;
  const double strut_d_in = argc > 7 ? std::atof(argv[7]) : 0.80;
  const double box_mm = argc > 8 ? std::atof(argv[8]) : 40.0;
  // v2: GRADE TO FIT SHAPE — within this band of the sub-box's faces the cell is
  // pulled toward d_min regardless of stress, so the SHAPE reads full and crisp
  // (the maintainer's "the top is very sparse — fill it in to match the shape").
  // 0 disables; the driver is min(stress map, face map).
  const double shape_band = argc > 9 ? std::atof(argv[9]) : 0.0;
  // v2: a gentle, deterministic swirl on the trace — "as if it grew out of a real
  // seed". Spatially coherent (sine products, no RNG), so neighbouring strands lean
  // together; the amplitude is small enough that steep strands stay steep, and the
  // flat-run law downstream disciplines anything that drifts shallow.
  const double swirl_amp = argc > 10 ? std::atof(argv[10]) : 0.0;
  // v2: 1 = bead grades with the local cell; 0 = the coupon's uniform bead — the
  // printed sample's calm comes partly from every strand being the same 0.8 mm.
  // ★★★ THE STRUT SCALING LAW (his ask, after holding the 3-8 mm print): "as the
  // lattice gets bigger ... the struts get thicker FROM THE ORIGINAL GRADED SIZE".
  // Anchored exactly there — d_min carries the stated strut_d, and a cell of local
  // size s carries strut_d * (s / d_min)^bead_pow.
  //
  //   0.0 = uniform bead everywhere (what the coupon and the printed cubes used)
  //   1.0 = LINEAR, i.e. constant relative density — the production law's own shape
  //         (organic_strut_diameter_for is linear in spacing at fixed rho), so an
  //         8 mm cell gets 2.13 mm of strut against 3 mm's 0.80
  //   ~0.6 = tempered: 8 mm cells reach ~1.4 mm, visibly beefier without going rope
  //
  // This is why the 3-8 mm cube felt flimsy where it opened up: at a uniform bead the
  // material fraction falls as the SQUARE of the cell, so the coarse regions carried
  // roughly a seventh of the fine regions' density.
  const double bead_pow = argc > 11 ? std::atof(argv[11]) : 0.0;
  // ★★★ "EASIER PRINTING" — the printability ENFORCEMENT, now an option rather than
  // a law. The maintainer printed the raw uniform flow cube (worst-case unsupported
  // bound 300 mm) and it came off the plate clean: the bridging physics carried
  // geometry this pass would have reshaped. So enforcement is a CHOICE. On (default):
  // shallow runs flatten to single-layer ribbons or bow into lid-capped arches, ties
  // are level-or-steep, and one-legged bridges are excised to a fixed point. Off: the
  // trace ships as traced — every strut a cylinder, nothing reshaped, nothing cut.
  //
  // The CENSUS RUNS EITHER WAY. Measuring is not enforcing: an unenforced run still
  // reports how many bridges stand on two legs, so the file's risk is stated rather
  // than hidden. That is the whole difference between this and deleting the code.
  const bool enforce_print = argc > 12 ? (std::atoi(argv[12]) != 0) : true;

  // ══ ★★★ THE SCALING LAW — THE PERFECTED CUBE IS THE REFERENCE ★★★ ═══════════
  //
  // The maintainer's printed 40 mm cube at 3-6 mm cells and 0.80 mm struts is the
  // anchor for a whole family of parts: "as the model gets bigger and the cells get
  // bigger because of the model being bigger, the struts get thicker". Given a box
  // of size L, with k = L / 40:
  //
  //     cells  = 3-6 mm  *  k^0.75      (grow SLOWER than the part)
  //     struts = 0.80 mm *  k^1.00      (grow WITH the part)
  //
  // Both exponents come from his own worked example — an 80 mm cube wanting a
  // "conservative 5-10 mm" window at "twice the thickness": 5/3 = 2^0.74, and
  // 1.6/0.8 = 2^1.0. The consequence is deliberate and worth stating, because it is
  // what makes the family structurally sane rather than merely photocopied: a bigger
  // part gets a RELATIVELY FINER, DENSER lattice. A pure photocopy (cells also at
  // k^1) would hold the look but thin the part in proportion to its own weight and
  // span, which is the wrong direction for something that has to carry more.
  //
  // Set autoscale to derive d_min/d_max/strut_d from box_mm; the explicitly passed
  // values are then ignored and the derived ones reported.
  const bool autoscale = argc > 13 ? (std::atoi(argv[13]) != 0) : false;
  const double kRefBoxMm = 40.0, kRefCellMin = 3.0, kRefCellMax = 6.0;
  const double kRefStrutMm = 0.80;
  // ★★ EQUAL EXPONENTS PRESERVE THE PROPORTIONS. The first cut used 0.75 for cells
  // against 1.00 for struts, from the maintainer's 80 mm example — and he then held
  // the result and said a 10 mm cell is too big. Two things were wrong with it:
  // 10.09 mm cells are coarse in ABSOLUTE terms (print physics — nozzle, layer,
  // bridging — does not scale with the part), and unequal exponents change the
  // cell:strut ratio, so a scaled part is no longer the same lattice.
  //
  // At cell^p and strut^p with the SAME p, every cell is a photocopy of a reference
  // cell — ratio 3.8-7.5 at any size — and only the absolute grain and the count
  // change. p then means one thing only: how fast the grain coarsens to keep the
  // strut count sane. p = 0.5 gives an 80 mm cube 4.24-8.49 mm cells at 1.13 mm
  // struts for 2.8x the reference's struts; p = 0 never coarsens (8x the struts);
  // p = 1 is a pure photocopy that gets relatively weaker as it grows.
  const double kCellPow = argc > 14 ? std::atof(argv[14]) : 0.50;
  const double kStrutPow = argc > 15 ? std::atof(argv[15]) : 0.50;
  // ★ argv[16]: stop each anchor leg at the part's own underside instead of at the
  // bottom of the bounding box. Default OFF so every cube run stays bit-for-bit what
  // it was; the run REPORTS what the flag would change either way.
  // 0 = drop to the bounding-box floor (the coupon's plate), 1 = stop at the part's
  // own underside, 2 = NO ANCHORS AT ALL.
  // ★ 2 is the one that matters for an embedded region. An anchor is a leg to the
  // build plate: it exists because a coupon has nothing else to stand on. Inside a
  // part the surrounding solid holds the lattice, and one plumb leg per curve — here
  // 5174 of them against 5664 traced curves — is simply a second, straight lattice
  // laid over the woven one. It is the "columnar" look, not the tracing.
  const int anchor_mode = argc > 16 ? std::atoi(argv[16]) : 0;
  const bool anchor_to_material = (anchor_mode == 1);
  // ★ argv[17]: CONFINE THE LATTICE TO DECLARED REGIONS. A real job does not ask for
  // a wholly latticed part — it names the areas. On the maintainer's stand that is
  // TWO WALLS, each a CAD face swept inward (12 mm and 13 mm) and clipped to that
  // face's own outline. Everything outside stays solid and is not ours to draw. The
  // sidecar carries what this branch's job loader cannot yet read (`outline_uv`).
  const std::string regions_path = argc > 17 ? argv[17] : std::string();
  // ★ argv[18]: the welded (marching-cubes) body is the big file — hundreds of MB on
  // a cube, potentially many GB on a full part. Exploratory runs want the counts and
  // the soup, not the gigabytes.
  const bool emit_welded = argc > 18 ? (std::atoi(argv[18]) != 0) : true;
  // ★ argv[19]: GRADE TO SOLID AT THE EDGES. Where a declared region abuts material
  // the job is KEEPING solid, the lattice must not simply stop in mid-air: it welds
  // into a solid rim of this thickness, so the surrounding walls carry it. The
  // region's OPEN faces (where the region meets the outside world) stay open — that
  // is the face you look at, and skinning it would hide the lattice entirely.
  const double rim_mm_in = argc > 19 ? std::atof(argv[19]) : 0.0;
  // ★ argv[20]: EMIT THE PART, not just the lattice. The job keeps 44 % of this part
  // solid; writing only the woven 56 % produces a lattice cloud with nothing holding
  // it, which is neither the part nor printable. With this on, the file IS the part:
  // solid where the job keeps it, lattice inside the declared regions, one body.
  const bool emit_solid = argc > 20 ? (std::atoi(argv[20]) != 0) : false;
  // ★ argv[21]: take the kept solid from the STEP'S OWN TESSELLATION rather than from
  // the FEA voxel grid. The grid is 1.7 mm at resolution 128, so a voxel-stamped
  // solid wears a 1.7 mm staircase along every curved edge — plainly visible on the
  // stand's cradle. The CAD mesh rasterised at the connectivity pitch (0.19 mm) puts
  // that step an order of magnitude below the nozzle, and the region boundary is then
  // cut analytically, so the wall openings are crisp too.
  const bool solid_from_cad = argc > 21 ? (std::atoi(argv[21]) != 0) : false;
  // ★ argv[22]: REJECT SEEDS THAT DID NOT GROW. The only length gate a traced curve
  // ever had was `pts.size() < 3` — about two integration steps, well under a
  // millimetre. Every seed that stalled immediately became a stub: material that
  // carries no load, and on a printed wall a scatter of loose specks. Mebarki's
  // farthest-point paper rejects a streamline shorter than the saturation ratio
  // (1.6) times the local spacing; this is that gate, expressed in local cells.
  // 0 keeps the old behaviour.
  const double min_curve_cells = argc > 22 ? std::atof(argv[22]) : 0.0;
  // ★ argv[23]: d_test as a fraction of d_sep (Jobard & Lefer use 0.5). 1.0 is what
  // this generator did before — and what every cube so far was built with, so it
  // stays the default and those files remain reproducible.
  const double d_test_ratio = argc > 23 ? std::atof(argv[23]) : 1.0;
  // ★ argv[24]: how many prune rounds to run (0 = off). Dropping a strut can orphan
  // its neighbour, so this iterates; it stops early when a round removes nothing.
  const int prune_rounds = argc > 24 ? std::atoi(argv[24]) : 0;
  // ★ argv[25]: below this FRACTION OF PEAK von Mises the principal frame is noise,
  // so substitute a synthetic field (see the block where dfam is built). 0 = off.
  const double field_floor = argc > 25 ? std::atof(argv[25]) : 0.0;
  // ★ argv[26]: wavelength of that synthetic swirl, in mm. Bigger = longer, lazier
  // curves; smaller = tighter curl.
  const double synth_lambda = argc > 26 ? std::atof(argv[26]) : 60.0;
  // ★ argv[27]: how many focal points the synthetic load has. 2 gives one clean
  // sweep between a pull and a push; more gives a richer, busier field.
  const int synth_foci = argc > 27 ? std::atoi(argv[27]) : 4;
  // ★ argv[28]: softening radius, mm. Without it the 1/r^2 falloff would blow up at
  // a focus and pin every nearby curve straight at it; this sets how large and lazy
  // the arc around each focus is.
  const double synth_soft = argc > 28 ? std::atof(argv[28]) : 25.0;
  // ★ argv[29]: shortest shallow run the flat-run pass will touch, mm. 1.0 is the old
  // behaviour (everything). Higher spares the weave and treats only long spans.
  const double enforce_min_run_mm = argc > 29 ? std::atof(argv[29]) : 1.0;
  // ★ argv[30]: make every printability rule ask whether the lattice puts anything
  // UNDER the stretch, instead of judging by angle alone. 0 restores angle-only.
  const bool enforce_support_aware = argc > 30 ? (std::atoi(argv[30]) != 0) : true;
  // ★ argv[31]: LET THE LINES LEAN -- minimum climb, so a strut lands on the layer
  // it just laid. Tested on |d.z|: a line heading DOWN is as self-supporting as one
  // heading up. 0 = off.
  const double lean_deg = argc > 31 ? std::atof(argv[31]) : 0.0;
  const double lean_sin = (lean_deg > 0.0) ? std::sin(lean_deg * M_PI / 180.0) : 0.0;
  // ★ argv[32]: seed the LOAD-ALIGNED family denser. 1.0 = off.
  const double fam0_sep_mult = argc > 32 ? std::atof(argv[32]) : 1.0;
  // ★ argv[33]: dump the BEAM MODEL (every polyline segment is a frame element),
  // the node-resolved BCs/loads, and the global displacement fields that drive the
  // submodel. Written in FEA-grid coordinates, NOT the build-plate shift.
  const std::string beam_path = argc > 33 ? argv[33] : std::string();
  double d_min = d_min_in, d_max = d_max_in, strut_d = strut_d_in;
  // ★ autoscale is APPLIED BELOW, once the part's material bounding box is known.
  // On a real part the reference length is the PART'S OWN SPAN, not a box_mm the
  // caller had to guess; box_mm > 0 still means "a cube of exactly that size".

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

  // ★ THE WHOLE PART, before the lattice confinement zeroes `density` outside the
  // declared regions. The hybrid model needs the REAL solid to mesh hex into; reading
  // the confined array reports every solid voxel as "in a region" and yields no solid
  // at all.
  const std::vector<double> density_full = density;
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

  // ── ★ CONFINE THE LATTICE TO THE DECLARED REGIONS ───────────────────────────
  // The STRESS FIELD stays the whole part's — that is the physics, and it is what
  // gives the weave its meaning. Only the DRAWING is confined: density is zeroed
  // outside the declared regions, and every stage downstream (the fitted sub-box,
  // seeding, tracing, anchors, the void test) then keys off that same mask with no
  // further change. Outside the regions the part is solid and not ours to draw.
  const std::vector<double> density0 = density;     // the part BEFORE confinement
  const std::vector<FaceRegion> regions = load_regions(regions_path);
  // Say what was asked for and what was read, ALWAYS. A regions file that silently
  // parses to nothing looks exactly like a healthy whole-part run.
  std::printf("regions file: %s -> %zu region(s)\n",
              regions_path.empty() ? "(none given)" : regions_path.c_str(), regions.size());
  if (!regions_path.empty() && regions.empty()) {
    std::fprintf(stderr, "REFUSING: a regions file was given but parsed to zero "
                         "regions — that would silently lattice the whole part.\n");
    return 3;
  }
  if (!regions.empty()) {
    std::size_t kept = 0, dropped = 0;
    std::vector<std::size_t> per(regions.size(), 0);
    for (int k = 0; k < grid.nz; ++k) for (int j = 0; j < grid.ny; ++j) for (int i = 0; i < grid.nx; ++i) {
      const std::size_t e = grid.index(i, j, k);
      if (density[e] <= 0.5) continue;
      const Vec3 q{grid.origin.x + (i + .5) * grid.spacing,
                   grid.origin.y + (j + .5) * grid.spacing,
                   grid.origin.z + (k + .5) * grid.spacing};
      bool inc = false, exc = false;
      for (std::size_t r = 0; r < regions.size(); ++r)
        if (region_contains_point(regions[r], q)) {
          if (regions[r].include) { inc = true; ++per[r]; } else { exc = true; }
        }
      if (inc && !exc) ++kept; else { density[e] = 0.0; ++dropped; }
    }
    std::printf("regions: %zu declared — lattice CONFINED to %zu voxels "
                "(%zu left solid, %.1f%% of the part is lattice)\n",
                regions.size(), kept, dropped,
                100.0 * double(kept) / double(kept + dropped));
    for (std::size_t r = 0; r < regions.size(); ++r)
      std::printf("  region %zu: %s, depth %.1f mm along (%.0f,%.0f,%.0f) -> %zu voxels%s\n",
                  r, regions[r].include ? "include" : "exclude", regions[r].depth,
                  regions[r].normal.x, regions[r].normal.y, regions[r].normal.z, per[r],
                  per[r] == 0 ? "   ** EMPTY — check the outline/basis" : "");
    if (kept == 0) {
      std::fprintf(stderr, "REFUSING: the declared regions contain no material — "
                           "nothing to lattice.\n");
      return 3;
    }
  }

  // ── ★ TWO DISTANCE FIELDS ON THE PART GRID ──────────────────────────────────
  //  bdist : how deep inside the lattice region a voxel sits (distance to the
  //          nearest voxel that is NOT lattice). This is what "grade to fit shape"
  //          actually means on a real region — the sub-box-face proxy the coupon
  //          used only ever described a cube.
  //  cdist : distance to the nearest voxel that is SOLID IN THE PART BUT OUTSIDE
  //          the region — i.e. to the material the job is keeping. That is where
  //          the lattice has to become solid so the walls can hold it. Distance to
  //          the OPEN boundary (region meets air) is deliberately not in cdist.
  auto dist_field = [&](const std::vector<unsigned char>& seed, double maxd) {
    std::vector<float> d(grid.voxel_count(), float(maxd));
    for (std::size_t e = 0; e < d.size(); ++e) if (seed[e]) d[e] = 0.0f;
    const float w1 = float(grid.spacing), w2 = float(grid.spacing * 1.41421356237),
                w3 = float(grid.spacing * 1.73205080757);
    const int iters = int(maxd / std::max(1e-9, grid.spacing)) + 2;
    for (int it = 0; it < iters; ++it) {
      bool changed = false;
      for (int k = 0; k < grid.nz; ++k) for (int j = 0; j < grid.ny; ++j) for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        float best = d[e];
        if (best <= 0.0f) continue;
        for (int dk = -1; dk <= 1; ++dk) for (int dj = -1; dj <= 1; ++dj) for (int di = -1; di <= 1; ++di) {
          if (!di && !dj && !dk) continue;
          const int ii = i + di, jj = j + dj, kk = k + dk;
          if (ii < 0 || jj < 0 || kk < 0 || ii >= grid.nx || jj >= grid.ny || kk >= grid.nz) continue;
          const int m = std::abs(di) + std::abs(dj) + std::abs(dk);
          const float v = d[grid.index(ii, jj, kk)] + (m == 1 ? w1 : m == 2 ? w2 : w3);
          if (v < best) best = v;
        }
        if (best < d[e] - 1e-6f) { d[e] = best; changed = true; }
      }
      if (!changed) break;
    }
    return d; };

  double rim_mm = rim_mm_in;
  std::vector<float> bdist, cdist;
  if (!regions.empty()) {
    const double bmax = std::max(shape_band, 1.0);
    std::vector<unsigned char> seed_b(grid.voxel_count(), 0), seed_c(grid.voxel_count(), 0);
    std::size_t nconnect = 0;
    for (std::size_t e = 0; e < density.size(); ++e) {
      if (density[e] <= 0.5) seed_b[e] = 1;                       // not lattice
      if (density0[e] > 0.5 && density[e] <= 0.5) { seed_c[e] = 1; ++nconnect; }
    }
    bdist = dist_field(seed_b, bmax);
    // ★ A RIM THINNER THAN ONE VOXEL SELECTS NOTHING. cdist is quantised to the FEA
    // grid, so the smallest non-zero distance any lattice voxel can have is one
    // spacing. At resolution 64 that is 3.41 mm and a 2 mm rim silently came out
    // EMPTY — which then made every strut read as unsupported. Clamp and say so.
    rim_mm = rim_mm_in;
    if (rim_mm > 0.0 && rim_mm < 1.05 * grid.spacing) {
      rim_mm = 1.05 * grid.spacing;
      std::printf("rim: %.2f mm is thinner than one voxel (%.2f mm) at this "
                  "resolution — raised to %.2f mm\n", rim_mm_in, grid.spacing, rim_mm);
    }
    cdist = dist_field(seed_c, std::max(rim_mm, 1.0) + 2.0 * grid.spacing);
    std::printf("edges: %zu voxels of KEPT SOLID border the regions; "
                "rim = %.2f mm (0 = none)\n", nconnect, rim_mm);
  }

  // ── ★ THE PART'S OWN MATERIAL BOUNDING BOX ──────────────────────────────────
  // The coupon's window is a CUBE centred on the solid centroid: right for a wall
  // cut out of a part, wrong for a finished part, where the window has to BE the
  // part. box_mm <= 0 selects part-fit; a positive box_mm keeps the cube exactly.
  Vec3 mlo{1e30, 1e30, 1e30}, mhi{-1e30, -1e30, -1e30};
  for (int k = 0; k < grid.nz; ++k) for (int j = 0; j < grid.ny; ++j) for (int i = 0; i < grid.nx; ++i)
    if (density[grid.index(i, j, k)] > 0.5) {
      const Vec3 q{grid.origin.x + (i + .5) * grid.spacing,
                   grid.origin.y + (j + .5) * grid.spacing,
                   grid.origin.z + (k + .5) * grid.spacing};
      mlo.x = std::min(mlo.x, q.x); mhi.x = std::max(mhi.x, q.x);
      mlo.y = std::min(mlo.y, q.y); mhi.y = std::max(mhi.y, q.y);
      mlo.z = std::min(mlo.z, q.z); mhi.z = std::max(mhi.z, q.z);
    }
  const bool fit_part = (box_mm <= 0.0);
  std::printf("part material bbox: %.1f x %.1f x %.1f mm\n",
              mhi.x - mlo.x, mhi.y - mlo.y, mhi.z - mlo.z);
  const double part_span =
      fit_part ? std::max(mhi.x - mlo.x, std::max(mhi.y - mlo.y, mhi.z - mlo.z)) : box_mm;
  if (autoscale) {
    const double k = part_span / kRefBoxMm;
    const double kc = std::pow(k, kCellPow);
    d_min = kRefCellMin * kc;
    d_max = kRefCellMax * kc;
    strut_d = kRefStrutMm * std::pow(k, kStrutPow);
    std::printf("autoscale: %.0f mm %s (k=%.2f, cell^%.2f strut^%.2f) -> cells "
                "%.2f-%.2f mm, struts %.2f mm, cell:strut %.1f-%.1f\n",
                part_span, fit_part ? "part span" : "box", k, kCellPow, kStrutPow,
                d_min, d_max, strut_d, d_min / strut_d, d_max / strut_d);
  }

  // ── v2: d_sep AS A FIELD. CDF-map the von Mises magnitude over solid voxels to
  // [d_min, d_max]: the 95th percentile and above gets d_min (small cells where the
  // load is), the 5th and below gets d_max. CDF, not linear, so one hot spot cannot
  // flatten the whole map (the field spans decades).
  std::vector<float> dsep_vox(grid.voxel_count(), float(d_max));
  {
    std::vector<double> vals;
    for (std::size_t e = 0; e < grid.voxel_count(); ++e)
      if (density[e] > 0.5) vals.push_back(a.von_mises_field[e]);
    std::sort(vals.begin(), vals.end());
    const double lo5 = vals[std::size_t(0.05 * (vals.size() - 1))];
    const double hi95 = vals[std::size_t(0.95 * (vals.size() - 1))];
    auto cdf = [&](double v) {
      const std::size_t r2 =
          std::lower_bound(vals.begin(), vals.end(), v) - vals.begin();
      return double(r2) / double(vals.size() - 1);
    };
    const double c5 = cdf(lo5), c95 = cdf(hi95);
    for (std::size_t e = 0; e < grid.voxel_count(); ++e) {
      if (density[e] <= 0.5) continue;
      double t = (cdf(a.von_mises_field[e]) - c5) / std::max(1e-9, c95 - c5);
      t = std::min(1.0, std::max(0.0, t));
      dsep_vox[e] = float(d_max - (d_max - d_min) * t);
    }
    std::printf("graded d_sep: %.2f (hot) .. %.2f (cold) mm\n", d_min, d_max);
  }

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
  // ── ★★ A SYNTHETIC LOAD, NOT A SYNTHETIC SWIRL ──────────────────────────────
  // The first attempt handed the dead wall an ABC flow: smooth, divergence-free, and
  // WRONG, because it is isotropic — every direction is as good as every other, so
  // the curves wander without ever agreeing on a destination. It read as a finer
  // mess, not as structure.
  //
  // A real stress field does not wander: it has FOCAL POINTS, and its curvature is
  // the flow of force between them. So build an actual TENSOR the way a load does —
  // a sum of rank-one contributions w/(r*r) (r ⊗ r) from a few focal points — and
  // take its principal directions with the same eigensolver the real field uses.
  // r ⊗ r is sign-invariant, which is why this has to be a tensor sum and not a
  // vector sum: opposing foci would otherwise cancel to nothing instead of forming
  // the saddle between them, and the saddle IS the sweeping curve.
  //
  // Alternating the sign of the weights makes half the foci pull and half push, so
  // the major family arcs BETWEEN them rather than starbursting out of each one.
  std::vector<Vec3> foci; std::vector<double> foci_w;
  auto synth_frame = [&](const Vec3& q, Vec3 out[3]) -> bool {
    if (foci.empty()) return false;
    double T[6] = {0, 0, 0, 0, 0, 0};
    for (std::size_t i = 0; i < foci.size(); ++i) {
      const Vec3 d = vsub(q, foci[i]);
      const double L = vnorm(d);
      if (L < 1e-9) continue;
      const Vec3 r = vscale(d, 1.0 / L);
      const double wg = foci_w[i] / (L * L + synth_soft * synth_soft);
      T[0] += wg * r.x * r.x; T[1] += wg * r.y * r.y; T[2] += wg * r.z * r.z;
      T[3] += wg * r.x * r.y; T[4] += wg * r.y * r.z; T[5] += wg * r.x * r.z;
    }
    double V[3][3], w[3]; jacobi3(T, V, w);
    int idx[3] = {0, 1, 2};
    for (int i = 0; i < 3; ++i) for (int j = i + 1; j < 3; ++j)
      if (std::fabs(w[idx[j]]) > std::fabs(w[idx[i]])) std::swap(idx[i], idx[j]);
    for (int f = 0; f < 3; ++f) {
      out[f] = Vec3{V[0][idx[f]], V[1][idx[f]], V[2][idx[f]]};
      if (!(vnorm(out[f]) > 1e-9)) return false;
      out[f] = vunit(out[f]);
    }
    return true; };

  // ── ★★ A WALL THAT CARRIES NOTHING HAS NO FIELD TO TRACE ────────────────────
  // The weave IS the stress field, which is exactly why it falls apart where there
  // is no stress: with von Mises near zero the three principal directions are
  // numerical noise, so the eigenvectors point wherever rounding sends them and the
  // "lattice" is a scribble. No amount of tracing, pruning or printability work can
  // fix that — the input carries no information.
  //
  // So where the field goes quiet, hand the tracer a SYNTHETIC one: a smooth,
  // divergence-free swirl (the same field already used to bend the traced curves),
  // turned into an orthonormal frame so the three families stay mutually
  // perpendicular exactly as principal directions are. The blend is by stress
  // magnitude, so a loaded wall is untouched, a dead wall is entirely synthetic, and
  // anything between crosses over smoothly instead of switching.
  {
    std::vector<double> vm_solid;
    for (std::size_t e = 0; e < a.von_mises_field.size(); ++e)
      if (density0[e] > 0.5) vm_solid.push_back(a.von_mises_field[e]);
    std::sort(vm_solid.begin(), vm_solid.end());
    auto pct = [&](double f) {
      return vm_solid.empty() ? 0.0
           : vm_solid[std::min(vm_solid.size() - 1, std::size_t(f * vm_solid.size()))]; };
    std::printf("stress field: vM p05=%.3g p50=%.3g p95=%.3g peak=%.3g MPa\n",
                pct(0.05), pct(0.50), pct(0.95), peak);
    for (std::size_t r = 0; r < regions.size(); ++r) {
      std::vector<double> v;
      for (int k = 0; k < grid.nz; ++k) for (int j = 0; j < grid.ny; ++j) for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (density[e] <= 0.5) continue;
        const Vec3 q{grid.origin.x + (i + .5) * grid.spacing,
                     grid.origin.y + (j + .5) * grid.spacing,
                     grid.origin.z + (k + .5) * grid.spacing};
        if (region_contains_point(regions[r], q)) v.push_back(a.von_mises_field[e]);
      }
      std::sort(v.begin(), v.end());
      std::printf("  region %zu: vM p05=%.3g p50=%.3g p95=%.3g MPa  (%zu voxels)%s\n", r,
                  v.empty() ? 0.0 : v[v.size() / 20], v.empty() ? 0.0 : v[v.size() / 2],
                  v.empty() ? 0.0 : v[std::min(v.size() - 1, v.size() * 19 / 20)], v.size(),
                  (!v.empty() && v[v.size() / 2] < 0.02 * peak) ? "   ** DEAD: no field to trace" : "");
    }
    if (field_floor > 0.0) {
      const double thr = field_floor * peak;
      // Where IS the dead material? The foci have to be placed against its own
      // geometry, or the arcs sweep somewhere the wall is not.
      Vec3 dlo{1e30,1e30,1e30}, dhi{-1e30,-1e30,-1e30}; std::size_t dn = 0;
      for (std::size_t e = 0; e < dfam[0].size(); ++e) {
        if (density[e] <= 0.5 || a.von_mises_field[e] >= thr) continue;
        const int i = int(e % grid.nx), j = int((e / grid.nx) % grid.ny),
                  k = int(e / (std::size_t(grid.nx) * grid.ny));
        const Vec3 q{grid.origin.x + (i + .5) * grid.spacing,
                     grid.origin.y + (j + .5) * grid.spacing,
                     grid.origin.z + (k + .5) * grid.spacing};
        dlo.x = std::min(dlo.x, q.x); dhi.x = std::max(dhi.x, q.x);
        dlo.y = std::min(dlo.y, q.y); dhi.y = std::max(dhi.y, q.y);
        dlo.z = std::min(dlo.z, q.z); dhi.z = std::max(dhi.z, q.z);
        ++dn;
      }
      if (dn > 0 && synth_foci > 0) {
        const Vec3 c2{0.5 * (dlo.x + dhi.x), 0.5 * (dlo.y + dhi.y), 0.5 * (dlo.z + dhi.z)};
        const double ex2 = dhi.x - dlo.x, ey2 = dhi.y - dlo.y, ez2 = dhi.z - dlo.z;
        // the two LONGEST axes span the wall; the third is its thickness
        int a1 = 0, a2 = 1;
        if (ey2 > ex2 && ez2 > ex2) { a1 = 1; a2 = 2; }
        else if (ex2 >= ey2 && ez2 > ey2) { a1 = 0; a2 = 2; }
        const double h1 = 0.5 * (a1 == 0 ? ex2 : a1 == 1 ? ey2 : ez2);
        const double h2 = 0.5 * (a2 == 0 ? ex2 : a2 == 1 ? ey2 : ez2);
        for (int i = 0; i < synth_foci; ++i) {
          const double ang = 2.0 * 3.14159265358979323846 * i / synth_foci + 0.35;
          double off[3] = {0, 0, 0};
          off[a1] = 0.80 * h1 * std::cos(ang);
          off[a2] = 0.80 * h2 * std::sin(ang);
          foci.push_back(Vec3{c2.x + off[0], c2.y + off[1], c2.z + off[2]});
          foci_w.push_back((i % 2) ? -1.0 : 1.0);
        }
        std::printf("synthetic load: %d foci around the dead material "
                    "(%.0f x %.0f x %.0f mm), softening %.1f mm\n",
                    synth_foci, ex2, ey2, ez2, synth_soft);
      }
      std::size_t synth = 0, blended = 0;
      for (std::size_t e = 0; e < dfam[0].size(); ++e) {
        if (density[e] <= 0.5) continue;
        const double vm = a.von_mises_field[e];
        if (vm >= thr) continue;
        // ★ COMMIT TO ONE FIELD OR THE OTHER. A linear ramp from zero to the floor
        // left the dead wall at w = 0.25 — a quarter rounding-noise still mixed into
        // every direction — and only 79 voxels of 34 694 ever went fully synthetic.
        // Measured proof it was not working: changing the synthetic wavelength by
        // 1.7x moved the traced arc by 0.2 %, i.e. the field was not being followed.
        // Smoothstep between a LOW threshold (below it the field carries nothing, go
        // fully synthetic) and the floor (above it the real field rules), so each
        // wall gets a definite answer and only the genuine middle ground blends.
        const double lo = 0.25 * thr;
        double w = (vm - lo) / std::max(1e-30, thr - lo);
        w = std::max(0.0, std::min(1.0, w));
        w = w * w * (3.0 - 2.0 * w);                                  // 0 dead .. 1 live
        if (w < 0.05) ++synth; else ++blended;
        const int i = int(e % grid.nx), j = int((e / grid.nx) % grid.ny),
                  k = int(e / (std::size_t(grid.nx) * grid.ny));
        const Vec3 q{grid.origin.x + (i + .5) * grid.spacing,
                     grid.origin.y + (j + .5) * grid.spacing,
                     grid.origin.z + (k + .5) * grid.spacing};
        Vec3 syn[3];
        if (!synth_frame(q, syn)) continue;
        for (int f = 0; f < 3; ++f) {
          const Vec3 d0{dfam[f][e][0], dfam[f][e][1], dfam[f][e][2]};
          Vec3 mix{d0.x * w + syn[f].x * (1 - w), d0.y * w + syn[f].y * (1 - w),
                   d0.z * w + syn[f].z * (1 - w)};
          if (!(vnorm(mix) > 1e-9)) mix = syn[f];
          mix = vunit(mix);
          dfam[f][e] = {float(mix.x), float(mix.y), float(mix.z)};
        }
      }
      std::printf("field floor %.3f of peak: %zu voxels fully SYNTHETIC, %zu blended\n",
                  field_floor, synth, blended);
    }
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
  const double part_pad = grid.spacing;
  const Vec3 blo = fit_part ? Vec3{mlo.x - part_pad, mlo.y - part_pad, mlo.z - part_pad}
                            : Vec3{c.x - h, c.y - h, c.z - h};
  const Vec3 bhi = fit_part ? Vec3{mhi.x + part_pad, mhi.y + part_pad, mhi.z + part_pad}
                            : Vec3{c.x + h, c.y + h, c.z + h};
  if (fit_part)
    std::printf("sub-box: PART FIT %.1f x %.1f x %.1f mm (material bbox + %.2f mm)\n",
                bhi.x - blo.x, bhi.y - blo.y, bhi.z - blo.z, part_pad);
  else
    std::printf("sub-box: %.1f mm cube centred at (%.1f, %.1f, %.1f)\n", box_mm, c.x, c.y, c.z);

  const double swirl_lam = part_span / 2.5;   // one bend held across several cells
  auto swirl_of = [&](const Vec3& q) {
    const double k2 = 2.0 * 3.14159265358979323846 / swirl_lam;
    const double x = q.x * k2, y = q.y * k2, z = q.z * k2;
    return Vec3{std::sin(y) * std::cos(z * 0.7 + 1.3),
                std::sin(z) * std::cos(x * 0.7 + 2.1),
                std::sin(x) * std::cos(y * 0.7 + 0.7)};
  };
  auto inbox = [&](const Vec3& p) {
    return p.x >= blo.x && p.x <= bhi.x && p.y >= blo.y && p.y <= bhi.y &&
           p.z >= blo.z && p.z <= bhi.z; };
  // ── v2: THE SHAPE TERM. Distance to the nearest sub-box face maps to
  // [d_min, d_max] across shape_band; the effective cell is the MIN of the stress
  // map and this — fine at every face of the SHAPE (top included, which the pure
  // stress map leaves cold and sparse), coarse only deep inside where neither
  // driver asks for material.
  if (shape_band > 0.0) {
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t e = grid.index(i, j, k);
          if (density[e] <= 0.5) continue;
          const Vec3 p{grid.origin.x + (i + .5) * grid.spacing,
                       grid.origin.y + (j + .5) * grid.spacing,
                       grid.origin.z + (k + .5) * grid.spacing};
          if (!inbox(p)) continue;
          // ★ On a declared region, "the shape" is the REGION, not the sub-box.
          const double bd = bdist.empty()
              ? std::min(std::min(std::min(p.x - blo.x, bhi.x - p.x),
                                  std::min(p.y - blo.y, bhi.y - p.y)),
                         std::min(p.z - blo.z, bhi.z - p.z))
              : double(bdist[e]);
          const double t = std::min(1.0, std::max(0.0, bd / shape_band));
          const double shape_dsep = d_min + (d_max - d_min) * t;
          if (shape_dsep < dsep_vox[e]) dsep_vox[e] = float(shape_dsep);
        }
    std::printf("shape fit: cells pulled to %.1f mm within %.1f mm of %s\n",
                d_min, shape_band,
                bdist.empty() ? "the sub-box faces" : "the REGION boundary");
  }
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
  // ★ IS THERE PLASTIC HERE? The coupon never had to ask — its part filled the box,
  // so an anchor could drop straight to the box floor and be sure of landing on
  // material. On a shaped part the same drop leaves the solid and hangs in mid-air.
  auto is_solid = [&](const Vec3& p) -> bool {
    const int i = int((p.x - grid.origin.x) / grid.spacing);
    const int j = int((p.y - grid.origin.y) / grid.spacing);
    const int k = int((p.z - grid.origin.z) / grid.spacing);
    if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz) return false;
    return density[grid.index(i, j, k)] > 0.5; };
  // ★ A HARD STOP AT THE REGION. is_solid alone is quantised to the FEA grid, so it
  // lets geometry drift up to a voxel outside; the analytic region test makes the
  // boundary exact. Anything the surgery MOVES (an arch is raised off the traced
  // path) has to be re-tested against this, or it leaves the wall it belongs to.
  auto inside_lattice = [&](const Vec3& p) -> bool {
    if (!regions.empty()) {
      bool in = false;
      for (const FaceRegion& fr : regions)
        if (fr.include && region_contains_point(fr, p)) { in = true; break; }
      if (!in) return false;
    }
    return is_solid(p); };

  // ── JOBARD & LEFER 1997: accept a curve only where it holds d_sep from the rest ─
  // Occupancy grid at d_sep resolution is the standard acceleration; a candidate
  // point is rejected when any already-accepted point lies within d_sep.
  // the bead a cell of local separation `sd` carries (see bead_pow)
  auto bead_for = [&](double sd) {
    if (!(bead_pow > 0.0)) return 0.5 * strut_d;
    const double f = std::pow(std::max(1e-9, sd) / std::max(1e-9, d_min), bead_pow);
    return 0.5 * strut_d * f;
  };
  int cur_fam = 0;
  auto dsep_at = [&](const Vec3& p) -> double {
    const int i = int((p.x - grid.origin.x) / grid.spacing);
    const int j = int((p.y - grid.origin.y) / grid.spacing);
    const int k = int((p.z - grid.origin.z) / grid.spacing);
    if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz)
      return d_max;
    const double base = double(dsep_vox[grid.index(i, j, k)]);
    return (cur_fam == 0) ? base * fam0_sep_mult : base;
  };
  const double cellg = d_max;   // bins must cover the WIDEST separation
  const int gx = std::max(1, int(part_span / cellg) + 2), gy = gx, gz = gx;
  // ★ SEPARATION IS PER FAMILY. Applying d_sep across ALL curves also forces
  // curves of DIFFERENT families apart, so the three families can never come
  // within connector range and the result is loose strands (measured: 6
  // connectors, 75 components). Each family is thinned against ITSELF; families
  // are free to interleave and cross, which is what ties the lattice together.
  std::vector<std::vector<Vec3>> bins[3] = {
      std::vector<std::vector<Vec3>>(std::size_t(gx) * gy * gz),
      std::vector<std::vector<Vec3>>(std::size_t(gx) * gy * gz),
      std::vector<std::vector<Vec3>>(std::size_t(gx) * gy * gz)};
  auto bin_of = [&](const Vec3& p, int& i, int& j, int& k) {
    i = std::min(gx - 1, std::max(0, int((p.x - blo.x) / cellg)));
    j = std::min(gy - 1, std::max(0, int((p.y - blo.y) / cellg)));
    k = std::min(gz - 1, std::max(0, int((p.z - blo.z) / cellg))); };
  // ★★ d_sep AND d_test ARE NOT THE SAME NUMBER. Jobard & Lefer use d_sep to place
  // SEEDS and a separate, SMALLER d_test to decide when an advancing streamline has
  // come close enough to an existing one to stop — they take d_test = 0.5 d_sep.
  // This code used d_sep for both, so every streamline died the instant it came
  // within one full cell of any curve of its own family. MEASURED consequence:
  // 55-78 % of all terminations were "own family", median arc 0.85 CELLS. That is
  // the stub field, and the sprouts that rise and stop for no visible reason.
  auto too_close = [&](const Vec3& p, double frac) {
    const double lim = frac * dsep_at(p);
    int i, j, k; bin_of(p, i, j, k);
    for (int dk = -1; dk <= 1; ++dk) for (int dj = -1; dj <= 1; ++dj) for (int di = -1; di <= 1; ++di) {
      const int ii = i + di, jj = j + dj, kk = k + dk;
      if (ii < 0 || jj < 0 || kk < 0 || ii >= gx || jj >= gy || kk >= gz) continue;
      for (const Vec3& q : bins[cur_fam][(std::size_t(kk) * gy + jj) * gx + ii])
        if (vnorm(vsub(p, q)) < lim) return true;          // LOCAL separation
    }
    return false; };
  auto deposit = [&](const Vec3& p) {
    int i, j, k; bin_of(p, i, j, k);
    bins[cur_fam][(std::size_t(k) * gy + j) * gx + i].push_back(p); };

  const double step = grid.spacing * 0.5;
  std::vector<Poly> curves;
  std::vector<int> curve_fam;
  std::vector<double> curve_dsep;   // the local separation at each curve's seed
  std::vector<float> curve_len_hist;          // arc length / local cell, per seed
  long long stubs_rejected = 0; double stub_mm = 0.0;
  // ★ WHY DOES A SPROUT STOP? Three possible answers and they call for opposite
  // fixes, so counting them is the whole point: it left the allotted volume, it ran
  // into a curve of its own family, or the stress field gave out. Per family,
  // because a thin wall has one principal direction across its 12 mm thickness and
  // every curve that follows it is SHORT BY GEOMETRY, not by failure.
  long long stop_outbox[3] = {0,0,0}, stop_close[3] = {0,0,0}, stop_field[3] = {0,0,0};
  long long fam_traced[3] = {0,0,0}, fam_kept[3] = {0,0,0};
  std::vector<float> fam_len[3];
  std::vector<std::vector<char>> curve_flat;  // per-point: inside a flattened run
  std::vector<std::vector<char>> curve_arch;  // per-point: inside a bowed-up arch
  const int seed_stride = std::max(1, int(d_min / grid.spacing));
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
      if (!inbox(s0) || too_close(s0, 1.0)) continue;   // SEEDING: full d_sep
      Poly fwd, bwd;
      for (int sgn = -1; sgn <= 1; sgn += 2) {
        Vec3 p = s0, prev{0, 0, 0}; bool hp = false;
        std::vector<Vec3>& acc = (sgn < 0 ? bwd.pts : fwd.pts);
        for (int s = 0; s < 4000; ++s) {
          Vec3 k1, k2, k3, k4;
          if (!sample(p, k1)) { ++stop_field[fam]; break; }
          if (!inbox(p)) { ++stop_outbox[fam]; break; }
          if (hp && (k1.x * prev.x + k1.y * prev.y + k1.z * prev.z) < 0) k1 = vscale(k1, -1);
          const double sd = sgn * step;
          if (!sample(vadd(p, vscale(k1, .5 * sd)), k2)) { ++stop_field[fam]; break; }
          if ((k2.x*k1.x + k2.y*k1.y + k2.z*k1.z) < 0) k2 = vscale(k2, -1);
          if (!sample(vadd(p, vscale(k2, .5 * sd)), k3)) { ++stop_field[fam]; break; }
          if ((k3.x*k1.x + k3.y*k1.y + k3.z*k1.z) < 0) k3 = vscale(k3, -1);
          if (!sample(vadd(p, vscale(k3, sd)), k4)) { ++stop_field[fam]; break; }
          if ((k4.x*k1.x + k4.y*k1.y + k4.z*k1.z) < 0) k4 = vscale(k4, -1);
          Vec3 d{(k1.x + 2*k2.x + 2*k3.x + k4.x) / 6, (k1.y + 2*k2.y + 2*k3.y + k4.y) / 6,
                 (k1.z + 2*k2.z + 2*k3.z + k4.z) / 6};
          if (!(vnorm(d) > 1e-12)) break;
          d = vunit(d);
          if (swirl_amp > 0.0) d = vunit(vadd(d, vscale(swirl_of(p), swirl_amp)));
          if (lean_sin > 0.0 && std::fabs(d.z) < lean_sin) {
            const double h = std::sqrt(d.x * d.x + d.y * d.y);
            const double want_h = std::sqrt(std::max(0.0, 1.0 - lean_sin * lean_sin));
            const double sz = (d.z < 0.0) ? -lean_sin : lean_sin;
            d = (h > 1e-12) ? Vec3{d.x / h * want_h, d.y / h * want_h, sz}
                            : Vec3{0.0, 0.0, (d.z < 0.0) ? -1.0 : 1.0};
          }
          const Vec3 np = vadd(p, vscale(d, sd));
          if (!inbox(np)) { ++stop_outbox[fam]; break; }
          if (too_close(np, d_test_ratio)) { ++stop_close[fam]; break; }   // WALKING: d_test
          acc.push_back(np); p = np; prev = d; hp = true;
        }
      }
      Poly cur;
      for (auto it = bwd.pts.rbegin(); it != bwd.pts.rend(); ++it) cur.pts.push_back(*it);
      cur.pts.push_back(s0);
      for (const Vec3& q : fwd.pts) cur.pts.push_back(q);
      if (cur.pts.size() < 3) continue;
      // ★ DID THIS SEED ACTUALLY GROW? Measure the arc, always; reject it when a gate
      // is set. A rejected stub is NOT deposited into the spacing field either — the
      // point of rejecting it is to leave that ground free for a seed that does grow,
      // and depositing would reserve the space for a curve that no longer exists.
      double curlen = 0.0;
      for (std::size_t q = 1; q < cur.pts.size(); ++q)
        curlen += vnorm(vsub(cur.pts[q], cur.pts[q - 1]));
      const double cur_dsep = dsep_at(s0);
      curve_len_hist.push_back(float(curlen / std::max(1e-9, cur_dsep)));
      ++fam_traced[fam]; fam_len[fam].push_back(float(curlen / std::max(1e-9, cur_dsep)));
      if (min_curve_cells > 0.0 && curlen < min_curve_cells * cur_dsep) {
        ++stubs_rejected; stub_mm += curlen; continue;
      }
      ++fam_kept[fam];
      for (const Vec3& q : cur.pts) deposit(q);
      curve_flat.emplace_back(cur.pts.size(), 0);
      curve_arch.emplace_back(cur.pts.size(), 0);
      curves.push_back(std::move(cur));
      curve_fam.push_back(fam);
      curve_dsep.push_back(dsep_at(s0));
    }
  }


  {
    std::vector<float> h = curve_len_hist;
    std::sort(h.begin(), h.end());
    auto pc = [&](double f) { return h.empty() ? 0.0f : h[std::min(h.size() - 1,
        std::size_t(f * double(h.size())))]; };
    std::size_t under1 = 0, under2 = 0;
    for (float v : h) { if (v < 1.0f) ++under1; if (v < 2.0f) ++under2; }
    std::printf("seed growth: %zu traced; arc/cell p05=%.2f median=%.2f p95=%.2f  "
                "— %zu (%.1f%%) grew under ONE cell, %zu (%.1f%%) under two\n",
                h.size(), pc(0.05), pc(0.50), pc(0.95), under1,
                100.0 * double(under1) / double(std::max<std::size_t>(1, h.size())),
                under2, 100.0 * double(under2) / double(std::max<std::size_t>(1, h.size())));
    if (min_curve_cells > 0.0)
      std::printf("             gate %.2f cells: %lld stubs rejected (%.1f mm), "
                  "%zu curves kept\n", min_curve_cells, stubs_rejected, stub_mm, curves.size());
    for (int f2 = 0; f2 < 3; ++f2) {
      std::vector<float> fl = fam_len[f2];
      std::sort(fl.begin(), fl.end());
      const float med = fl.empty() ? 0.0f : fl[fl.size() / 2];
      const long long tot = stop_outbox[f2] + stop_close[f2] + stop_field[f2];
      std::printf("  family %d: %lld traced -> %lld kept, median arc %.2f cells; "
                  "stopped by EDGE %.0f%% / OWN FAMILY %.0f%% / FIELD %.0f%%\n",
                  f2, fam_traced[f2], fam_kept[f2], med,
                  100.0 * double(stop_outbox[f2]) / double(std::max(1LL, tot)),
                  100.0 * double(stop_close[f2]) / double(std::max(1LL, tot)),
                  100.0 * double(stop_field[f2]) / double(std::max(1LL, tot)));
    }
  }

  // ── ★★ THE PRINTED RULE IS ENFORCED BY THE CENSUS FIXED POINT, NOT A PRE-TRIM.
  // v2 first trimmed one-legged shallow tails BEFORE the connectors were tied, on
  // the reasoning that nothing should tie to a doomed tail. The slicer showed the
  // cost, top ~100 layers side by side: the untrimmed uniform cube carried a dense
  // web of connectors bridging the strut tops; the trimmed one was almost bare.
  // At the top, a shallow tail's second leg IS a connector — cutting the tail
  // before connectors exist destroys the very web that would have made it legal.
  // So no material is removed here: the census below runs to a fixed point WITH
  // connectors and anchors as legs, excises only what nothing can save, and the
  // dangling-connector filter cleans up ties into whatever was excised.
  double trimmed_mm = 0.0;
  std::size_t trimmed_ends = 0;

  // ── ★★★ FLATTEN-OR-EXCISE THE CURVE RUNS — the tie law, applied to the curves
  // themselves. The maintainer re-sliced after the ribbon ties and the stepped
  // bridge was STILL there: 20+ mm long, far past any tie's reach. It was a traced
  // curve's shallow run — census-legal (two legs), but an undulating CYLINDER
  // chain, stepping across layers exactly like the ties used to. The wall that
  // printed had 3-7 mm runs; this cube grows them to 183 mm (p90 24.8), a
  // different animal, and "proven by plastic" does not transfer.
  //
  // So every maximal shallow run (every segment under 30 deg, arc >= 1 mm) now
  // obeys the tie regimes: z-span <= 1 mm -> FLATTENED to one exact plane (each
  // point moves <= 0.5 mm, within its own bead) and emitted as a flat-bottomed
  // ribbon chain; a wider z-span is a shallowly CLIMBING run — an unlevelable
  // stepped cantilever, the precise object his layer sweep condemned — and is
  // EXCISED, splitting the curve. Runs before connectors, so ties land on the
  // flattened coordinates; the census fixed point then re-verifies every leg.
  // ── ★★ IS THERE ANYTHING UNDER IT? ──────────────────────────────────────────
  // Every printability rule below used to key on ANGLE ALONE. That is why enforcement
  // cost 1088 curves on a part whose real bridging, measured crossing-aware, tops out
  // at 6.82 mm: a shallow stretch resting on a dozen other struts was treated exactly
  // like one spanning open air. The nozzle does not care about the angle of the curve
  // it is drawing; it cares whether something is underneath to land on.
  //
  // So build the answer once and let all four rules ask it. The hash is over the
  // traced points as they stand BEFORE surgery, which is the lattice that will in
  // fact be there when this stretch prints.
  const double kSupReachXY = 1.5 * strut_d;   // a bead's worth of lateral overlap
  const double kSupReachZ = 4.0;              // how far below still counts
  std::unordered_map<long long, std::vector<Vec3>> sup_hash;
  {
    const double hc = std::max(1.0, kSupReachXY);
    for (const Poly& c2 : curves)
      for (const Vec3& q : c2.pts)
        sup_hash[(long long)int(std::floor(q.x / hc)) * 2654435761LL +
                 int(std::floor(q.y / hc))].push_back(q);
  }
  auto supported_below = [&](const Vec3& p) {
    if (!enforce_support_aware) return false;   // angle-only: the old behaviour
    const double hc = std::max(1.0, kSupReachXY);
    const int i0 = int(std::floor(p.x / hc)), j0 = int(std::floor(p.y / hc));
    for (int dj = -1; dj <= 1; ++dj) for (int di = -1; di <= 1; ++di) {
      auto it = sup_hash.find((long long)(i0 + di) * 2654435761LL + (j0 + dj));
      if (it == sup_hash.end()) continue;
      for (const Vec3& q : it->second) {
        const double dz = p.z - q.z;
        if (dz <= 0.05 || dz > kSupReachZ) continue;
        const double dx = p.x - q.x, dy = p.y - q.y;
        if (dx * dx + dy * dy <= kSupReachXY * kSupReachXY) return true;
      }
    }
    return false; };

  if (enforce_print) {
    const double kRunShallowSin = 0.5;     // under 30 deg: the stepping band
    const double kRunFlattenSpan = 1.0;    // flatten up to this z-span, else cut
    std::size_t runs_flattened = 0, runs_arched = 0, runs_lidcut = 0;
    double flat_mm = 0.0, arched_mm = 0.0, lidcut_mm = 0.0;
    std::vector<Poly> nc;
    std::vector<int> nf;
    std::vector<double> nd;
    std::vector<std::vector<char>> nfl, nar;
    for (std::size_t ci = 0; ci < curves.size(); ++ci) {
      auto& pp = curves[ci].pts;
      std::vector<char> flat(pp.size(), 0), drop(pp.size(), 0), arch(pp.size(), 0);
      std::size_t i = 1;
      while (i < pp.size()) {
        // find a maximal shallow stretch [rs, re]
        const Vec3 d0 = vsub(pp[i], pp[i - 1]);
        const double L0 = vnorm(d0);
        if (!(L0 > 1e-12) || std::fabs(d0.z) / L0 >= kRunShallowSin ||
            supported_below(pp[i])) { ++i; continue; }
        const std::size_t rs = i - 1;
        double arc = L0;
        std::size_t re = i;
        while (re + 1 < pp.size()) {
          const Vec3 d1 = vsub(pp[re + 1], pp[re]);
          const double L1 = vnorm(d1);
          if (!(L1 > 1e-12) || std::fabs(d1.z) / L1 >= kRunShallowSin) break;
          arc += L1; ++re;
        }
        // ★ ONLY THE RUNS THAT ARE ACTUALLY A PRINT RISK. This threshold was 1 mm,
        // so every shallow stretch in the part got flattened or arched — and short
        // shallow stretches ARE the weave, which is why "printability on" measured
        // 66 % shallow arc down to 40 % and looked combed. A 3 mm shallow run is not
        // what fails on the bed; a 50 mm one is. Raising the bar leaves the fabric
        // alone and still treats the spans that matter.
        if (arc >= enforce_min_run_mm) {
          double zlo = pp[rs].z, zhi = pp[rs].z, zsum = 0.0;
          for (std::size_t t = rs; t <= re; ++t) {
            zlo = std::min(zlo, pp[t].z); zhi = std::max(zhi, pp[t].z);
            zsum += pp[t].z;
          }
          if (zhi - zlo <= kRunFlattenSpan) {
            const double zc = zsum / double(re - rs + 1);
            for (std::size_t t = rs; t <= re; ++t) { pp[t].z = zc; flat[t] = 1; }
            ++runs_flattened; flat_mm += arc;
          } else {
            // ★★ BOW IT INTO AN ARCH instead of cutting it — the maintainer's own
            // earlier suggestion, and the production arch doctrine's geometry: bowed
            // UP, each half climbs from its own node, every layer lands on the
            // previous layer OF THE SAME STRUT, and the apex closes last. The rise
            // is set so each leg leaves at >= ~30 deg (pi*rise/L >= tan30), capped
            // at a quarter of the span. The excised flow comes back as arches.
            const double L = arc;
            const Vec3 z0 = pp[rs], z1 = pp[re];
            // ★★ THE LID. An arch near the top face bowed straight OUT of the cube —
            // the maintainer's slicer showed domes standing 3.6 mm proud of a
            // 40 mm part, gusseted triangles under them. An arch may rise only as
            // far as the box top minus a bead; if the room under the lid cannot
            // give the legs their ~30 degrees, there is no legal arch THERE, and
            // the run is excised instead — the silhouette is a promise.
            const double lid = bhi.z - 0.6;
            const double rise_need = std::max(0.1837 * L, zhi - zlo);
            const double rise_room = lid - std::max(z0.z, z1.z);
            bool arch_ok = rise_room >= rise_need;
            if (arch_ok) {
              double rise = std::min(std::min(rise_need + 0.25 * L, rise_room),
                                     0.25 * L + (zhi - zlo));
              rise = std::max(rise, rise_need);
              // ★ THE ARCH IS THE ONE THING THAT LEAVES THE PART. Every other point
              // was traced inside the material; these are LIFTED off it. Test the
              // raised arc, and if any of it escapes the region, lower the rise
              // until it fits — failing that, excise the run exactly as the lid does.
              std::vector<double> zs(re - rs + 1);
              for (int attempt = 0; attempt < 4; ++attempt) {
                bool ok = true;
                for (std::size_t t = rs; t <= re; ++t) {
                  const double u = double(t - rs) / double(re - rs);
                  const double chord = z0.z + (z1.z - z0.z) * u;
                  zs[t - rs] = chord + rise * std::sin(3.14159265358979323846 * u);
                  if (!inside_lattice(Vec3{pp[t].x, pp[t].y, zs[t - rs]})) { ok = false; break; }
                }
                if (ok) break;
                if (rise <= rise_need + 1e-9) { arch_ok = false; break; }
                rise = std::max(rise_need, rise * 0.6);
                if (attempt == 3) arch_ok = false;
              }
              if (arch_ok) {
                for (std::size_t t = rs; t <= re; ++t) { pp[t].z = zs[t - rs]; arch[t] = 1; }
                ++runs_arched; arched_mm += arc;
              }
            }
            if (!arch_ok) {
              for (std::size_t t = rs; t <= re; ++t) drop[t] = 1;
              ++runs_lidcut; lidcut_mm += arc;
            }
          }
        }
        i = re + 1;
      }
      // split at dropped stretches, carrying the flat flags
      Poly seg; std::vector<char> segf, sega;
      auto flush = [&]() {
        if (seg.pts.size() >= 3) {
          nc.push_back(seg); nf.push_back(curve_fam[ci]);
          nd.push_back(curve_dsep[ci]); nfl.push_back(segf); nar.push_back(sega);
        }
        seg.pts.clear(); segf.clear(); sega.clear();
      };
      for (std::size_t t = 0; t < pp.size(); ++t) {
        if (drop[t]) { flush(); continue; }
        seg.pts.push_back(pp[t]); segf.push_back(flat[t]); sega.push_back(arch[t]);
      }
      flush();
    }
    curves.swap(nc); curve_fam.swap(nf); curve_dsep.swap(nd); curve_flat.swap(nfl);
    curve_arch.swap(nar);
    std::printf("flat-run pass: %zu runs FLATTENED (%.0f mm), %zu ARCHED "
                "(%.0f mm), %zu EXCISED at the lid (%.0f mm)\n",
                runs_flattened, flat_mm, runs_arched, arched_mm,
                runs_lidcut, lidcut_mm);
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

  const double conn_max = 1.10 * d_max;   // bin at the widest; accept per-pair below
  // ── ★★ THE TWO LEGAL TIE REGIMES, from the maintainer's slicer observation. A tie
  // at angle theta from the plate advances layer/tan(theta) sideways PER LAYER: at
  // 45 deg that is one line width (self-supporting), at 5 deg it is a 1.4 mm
  // unsupported ledge on every layer — the stepped cantilevers his 0.12 mm slice
  // showed, each step a fresh overhang toward the eventual bridge. So every tie is
  // either LEVEL — |dz| within a layer, then snapped EXACTLY flat so the slicer
  // lays the whole bridge in one pass — or STEEP (>= 30 deg, step <= 0.21 mm).
  // The shallow-but-not-flat band between is refused. Snapping moves an endpoint
  // at most 0.075 mm off its curve's centreline, far inside the 0.4 mm radius.
  const double kTieLevelTol = 0.15;
  const double kTieSteepSin = 0.5;      // sin(30 deg)
  std::size_t ties_level = 0, ties_steep = 0, ties_refused_shallow = 0;
  auto tie_regime = [&](const Vec3& a2, const Vec3& b2) -> int {
    const double dd = vnorm(vsub(b2, a2));
    if (!(dd > 1e-9)) return -1;
    if (!enforce_print) return 2;      // accept as traced: neither refused nor snapped
    // ★ a tie resting on the lattice is not a stepped cantilever — accept it as traced
    if (supported_below(Vec3{0.5 * (a2.x + b2.x), 0.5 * (a2.y + b2.y),
                             0.5 * (a2.z + b2.z)})) return 2;
    const double adz = std::fabs(b2.z - a2.z);
    if (adz <= kTieLevelTol) return 0;                    // level (snap it)
    if (adz / dd >= kTieSteepSin) return 1;               // steep diagonal
    return -1;                                            // outlawed band
  };
  std::vector<std::array<Vec3, 2>> connectors;
  std::vector<char> conn_level;   // 1 = snapped level: emitted as a flat-bottom box
  std::vector<double> conn_r;     // the tie's own bead, from the finer cell it joins
  {
    const double cg = conn_max;
    const int nx2 = std::max(1, int(part_span / cg) + 2);
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
          const double lim = 1.10 * std::min(curve_dsep[pts[m].curve],
                                             curve_dsep[pts[n].curve]);
          if (!(dd > 1e-6) || dd > lim) continue;
          if (tie_regime(pts[n].p, pts[m].p) < 0) continue;   // no stepped ledges
          if (dd < best) { best = dd; bestn = m; }
        }
      }
      if (bestn >= 0 && bestn > int(n)) {
        Vec3 a2 = pts[n].p, b2 = pts[bestn].p;
        const int rg = tie_regime(a2, b2);
        if (rg == 0) {                       // snap EXACTLY level: one-layer bridge
          const double zc = 0.5 * (a2.z + b2.z);
          a2.z = zc; b2.z = zc; ++ties_level;
        } else ++ties_steep;
        connectors.push_back({a2, b2});
        conn_level.push_back(rg == 0 ? 1 : 0);
        conn_r.push_back(bead_for(std::min(curve_dsep[pts[n].curve],
                                           curve_dsep[pts[bestn].curve])));
      }
    }
  }

  // ── ★★ THE CAP — the top face's own web, the dual of the base slab. MEASURED,
  // slicer-style top views side by side: the uniform-3mm cube's top is a dense
  // knitted grid; every graded interior (3-5, 3-6, 3-8) leaves it sparse at 43-59 %
  // of the goal — because the web is knitted by connectors, and connector count
  // scales with the forest of struts arriving from BELOW, which an open interior
  // thins by design. Densifying the interior to fix the top is buying the wrong
  // thing. Instead the top band is knitted DELIBERATELY: every strut point in the
  // band ties to up to three nearby points of OTHER curves, any family, within
  // 1.15x the local cell. Both endpoints lie on anchored curves, so every tie is a
  // two-legged level bridge — the printed rule's geometry, verbatim.
  if (shape_band > 0.0) {
    std::vector<int> topn;
    for (std::size_t n2 = 0; n2 < pts.size(); ++n2)
      if (pts[n2].p.z > bhi.z - shape_band) topn.push_back(int(n2));
    const double cg2 = 1.15 * d_max;
    const int nx3 = std::max(1, int(part_span / cg2) + 2);
    std::vector<std::vector<int>> b3(std::size_t(nx3) * nx3 * nx3);
    auto bi3 = [&](const Vec3& q, int& i, int& j, int& k) {
      i = std::min(nx3 - 1, std::max(0, int((q.x - blo.x) / cg2)));
      j = std::min(nx3 - 1, std::max(0, int((q.y - blo.y) / cg2)));
      k = std::min(nx3 - 1, std::max(0, int((q.z - blo.z) / cg2))); };
    for (int n2 : topn) {
      int i, j, k; bi3(pts[n2].p, i, j, k);
      b3[(std::size_t(k) * nx3 + j) * nx3 + i].push_back(n2);
    }
    std::set<std::pair<int, int>> tied;
    std::size_t cap_ties = 0;
    for (int n2 : topn) {
      int i, j, k; bi3(pts[n2].p, i, j, k);
      std::vector<std::pair<double, int>> near;
      for (int dk = -1; dk <= 1; ++dk) for (int dj = -1; dj <= 1; ++dj) for (int di = -1; di <= 1; ++di) {
        const int ii = i + di, jj = j + dj, kk = k + dk;
        if (ii < 0 || jj < 0 || kk < 0 || ii >= nx3 || jj >= nx3 || kk >= nx3) continue;
        for (int m : b3[(std::size_t(kk) * nx3 + jj) * nx3 + ii]) {
          if (pts[m].curve == pts[n2].curve) continue;
          const double dd = vnorm(vsub(pts[m].p, pts[n2].p));
          const double lim = 1.15 * std::min(curve_dsep[pts[m].curve],
                                             curve_dsep[pts[n2].curve]);
          if (!(dd > 1e-6) || dd > lim) continue;
          const int rg = tie_regime(pts[n2].p, pts[m].p);
          if (rg < 0) { ++ties_refused_shallow; continue; }
          near.push_back({dd, m});
        }
      }
      std::sort(near.begin(), near.end());
      int made = 0;
      for (const auto& pr : near) {
        if (made >= 3) break;
        const int a2 = std::min(n2, pr.second), b4 = std::max(n2, pr.second);
        if (!tied.insert({a2, b4}).second) continue;
        Vec3 pa = pts[n2].p, pb = pts[pr.second].p;
        const int rg2 = tie_regime(pa, pb);
        if (rg2 == 0) {
          const double zc = 0.5 * (pa.z + pb.z);
          pa.z = zc; pb.z = zc; ++ties_level;
        } else ++ties_steep;
        connectors.push_back({pa, pb});
        conn_level.push_back(rg2 == 0 ? 1 : 0);
        conn_r.push_back(bead_for(std::min(curve_dsep[pts[n2].curve],
                                           curve_dsep[pts[pr.second].curve])));
        ++cap_ties; ++made;
      }
    }
    std::printf("cap: %zu top-band ties knitted (band %.1f mm)\n",
                cap_ties, shape_band);
    std::printf("tie regimes: %zu LEVEL (snapped flat), %zu steep (>=30 deg), "
                "%zu shallow-stepped REFUSED\n",
                ties_level, ties_steep, ties_refused_shallow);
  }

  // BASE ANCHORS: drop a vertical leg from the lowest point of any curve whose
  // lowest point sits above the slab, so nothing begins in mid air.
  long long anchors_through_air = 0; double air_total = 0.0;
  std::vector<std::array<Vec3, 2>> anchors;
  std::vector<double> anchor_r;
  for (std::size_t ci = 0; ci < curves.size(); ++ci) {
    const Poly& cc = curves[ci];
    const Vec3* low = &cc.pts[0];
    for (const Vec3& q : cc.pts) if (q.z < low->z) low = &q;
    if (anchor_mode == 2) continue;                 // the part holds it; no legs
    if (low->z > blo.z + 1e-6) {
      const double stz = 0.5 * grid.spacing;
      double zmat = low->z;                     // how far down is there MATERIAL?
      for (double z2 = low->z - stz; z2 >= blo.z; z2 -= stz) {
        if (!is_solid(Vec3{low->x, low->y, z2})) break;
        zmat = z2;
      }
      const double air = zmat - blo.z;          // leg length spent OUTSIDE the solid
      if (air > 0.5) { ++anchors_through_air; air_total += air; }
      const double zfoot = anchor_to_material ? zmat : blo.z;
      if (low->z - zfoot > 1e-6) {
        anchors.push_back({*low, Vec3{low->x, low->y, zfoot}});
        anchor_r.push_back(bead_for(curve_dsep[ci]));
      }
    }
  }
  std::printf("anchors: %zu placed (mode %d: %s); %lld would cross AIR below the "
              "part (%.1f mm of leg outside the solid)\n",
              anchors.size(), anchor_mode,
              anchor_mode == 2 ? "NONE — the part carries the lattice"
                               : anchor_mode == 1 ? "stop at the part's underside"
                                                  : "drop to the box floor",
              anchors_through_air, air_total);

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
  //
  // ★★ AND THAT BOUND IS THE WRONG INSTRUMENT FOR A DENSE WEAVE. It walks ONE curve
  // and keeps adding length for as long as the segment is shallow, whatever else the
  // lattice puts underneath it. On a sparse coupon that is honest. With 4000 crossing
  // curves, a "70 mm unsupported span" may be resting on a dozen other struts along
  // its length and never bridge more than a few millimetres of actual air. So measure
  // the same thing CROSSING-AWARE: break the run wherever some other curve passes
  // below it within reach, which is what the nozzle will actually land on.
  {
    const double reach_xy = 1.5 * strut_d;   // a bead's worth of lateral overlap
    const double reach_z = 4.0;              // how far below still counts as support
    const double hcell = std::max(1.0, reach_xy);
    std::unordered_map<long long, std::vector<Vec3>> hash;
    auto hkey = [&](int i, int j) { return (long long)i * 2654435761LL + j; };
    for (const Poly& c2 : curves)
      for (const Vec3& q : c2.pts)
        hash[hkey(int(std::floor(q.x / hcell)), int(std::floor(q.y / hcell)))].push_back(q);
    auto supported_below = [&](const Vec3& p) {
      const int i0 = int(std::floor(p.x / hcell)), j0 = int(std::floor(p.y / hcell));
      for (int dj = -1; dj <= 1; ++dj) for (int di = -1; di <= 1; ++di) {
        auto it = hash.find(hkey(i0 + di, j0 + dj));
        if (it == hash.end()) continue;
        for (const Vec3& q : it->second) {
          const double dz = p.z - q.z;
          if (dz <= 0.05 || dz > reach_z) continue;
          const double dx = p.x - q.x, dy = p.y - q.y;
          if (dx * dx + dy * dy <= reach_xy * reach_xy) return true;
        }
      }
      return false; };
    std::vector<double> cruns;
    for (const Poly& c2 : curves) {
      double run = 0;
      for (std::size_t i = 1; i < c2.pts.size(); ++i) {
        const Vec3 d = vsub(c2.pts[i], c2.pts[i - 1]);
        const double L = vnorm(d); if (!(L > 1e-12)) continue;
        const bool shallow = std::fabs(d.z) / L < std::sqrt(0.5);
        if (shallow && !supported_below(c2.pts[i])) run += L;
        else if (run > 0) { cruns.push_back(run); run = 0; }
      }
      if (run > 0) cruns.push_back(run);
    }
    std::sort(cruns.begin(), cruns.end());
    auto q = [&](double f) { return cruns.empty() ? 0.0
        : cruns[std::min(cruns.size() - 1, std::size_t(f * cruns.size()))]; };
    std::printf("unsupported runs CROSSING-AWARE: %zu runs, median %.2f  p90 %.2f  "
                "p99 %.2f  LONGEST %.2f mm\n", cruns.size(), q(0.50), q(0.90), q(0.99),
                cruns.empty() ? 0.0 : cruns.back());
  }

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

  // ── ★★ THE TWO-LEG CENSUS. Every maximal shallow run (>2 mm of contiguous arc
  // beyond 45 degrees) is a BRIDGE, and his rule says each needs both ends held —
  // by a crossing curve, a connector, an anchor, or the slab. Counted on the FINAL
  // geometry (post-trim, connectors and anchors included). The census is the
  // printability claim this coupon can honestly make; runs with fewer than two
  // legs are the defect his photographs showed.
  std::size_t bridges_two = 0, bridges_one = 0, bridges_zero = 0, bridges_arched = 0;
  std::size_t final_two = 0, final_bad = 0;
  // ★ SURGERY TO A FIXED POINT. One pass was measured insufficient: excising three
  // one-legged runs orphaned a neighbouring run's leg and the recount answered NO
  // (1 still short). An excision changes the support graph, so the census must run
  // again on what remains, until a round removes nothing.
  for (int srg_round = 0; srg_round < (enforce_print ? 6 : 1); ++srg_round) {
    bridges_two = 0; bridges_arched = 0;
    const std::size_t excised_before = bridges_one + bridges_zero;
    const double tc = 2.0;
    std::map<std::array<long long, 3>, std::vector<std::pair<Vec3, int>>> H;
    auto hk = [&](const Vec3& q) {
      return std::array<long long, 3>{(long long)std::floor(q.x / tc),
                                      (long long)std::floor(q.y / tc),
                                      (long long)std::floor(q.z / tc)};
    };
    for (std::size_t ci = 0; ci < curves.size(); ++ci)
      for (const Vec3& q : curves[ci].pts) H[hk(q)].push_back({q, int(ci)});
    int aux = int(curves.size());
    auto add_seg = [&](const Vec3& a2, const Vec3& b2) {
      const double L = vnorm(vsub(b2, a2));
      const int m = std::max(1, int(L / 0.5));
      for (int t = 0; t <= m; ++t)
        H[hk(vadd(a2, vscale(vsub(b2, a2), double(t) / m)))].push_back(
            {vadd(a2, vscale(vsub(b2, a2), double(t) / m)), aux});
      ++aux;
    };
    for (const auto& cn : connectors) add_seg(cn[0], cn[1]);
    for (const auto& an : anchors) add_seg(an[0], an[1]);
    auto held = [&](const Vec3& q, int self) {
      if (q.z <= blo.z + 0.5) return true;
      const auto k0 = hk(q);
      for (long long dz = -1; dz <= 1; ++dz)
        for (long long dy = -1; dy <= 1; ++dy)
          for (long long dx = -1; dx <= 1; ++dx) {
            auto it = H.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
            if (it == H.end()) continue;
            for (const auto& pr : it->second) {
              if (pr.second == self) continue;
              if (pr.first.z > q.z + 0.6) continue;
              if (vnorm(vsub(pr.first, q)) <= 1.2) return true;
            }
          }
      return false;
    };
    // ★ AND THE EXCISION: a mid-curve run with fewer than two legs — which the
    // tail trim cannot reach — is CUT OUT, splitting its curve. The census is then
    // clean BY CONSTRUCTION, not by luck: his rule admits no one-legged bridge, and
    // "all but one" is not a printability claim.
    double excised_mm = 0.0;
    std::vector<Vec3> dropped_pts;
    std::vector<Poly> rebuilt;
    std::vector<int> rebuilt_fam;
    std::vector<double> rebuilt_dsep;
    std::vector<std::vector<char>> rebuilt_flat, rebuilt_arch;
    for (std::size_t ci = 0; ci < curves.size(); ++ci) {
      const auto& pp = curves[ci].pts;
      std::vector<char> drop(pp.size(), 0);
      double run = 0; std::size_t rs = 0;
      auto close_run = [&](std::size_t re) {
        if (run < 2.0) { run = 0; return; }
        // ★ an ARCHED stretch is bowed UP: every layer lands on the previous layer
        // of the same strut (the production arch doctrine), so its brief shallow
        // apex needs no second leg — it is its own leg. Counted, never excised.
        bool arched = false;
        for (std::size_t t = rs; t <= re; ++t)
          if (curve_arch[ci][t]) { arched = true; break; }
        if (arched) { ++bridges_arched; run = 0; return; }
        const int legs = (held(pp[rs], int(ci)) ? 1 : 0) +
                         (held(pp[re], int(ci)) ? 1 : 0);
        if (legs == 2) ++bridges_two;
        else {
          if (legs == 1) ++bridges_one; else ++bridges_zero;
          if (enforce_print) {            // measuring is not enforcing
            excised_mm += run;
            for (std::size_t t = rs; t <= re; ++t) {
              drop[t] = 1; dropped_pts.push_back(pp[t]);
            }
          }
        }
        run = 0;
      };
      for (std::size_t i = 1; i < pp.size(); ++i) {
        const Vec3 d = vsub(pp[i], pp[i - 1]);
        const double L = vnorm(d); if (!(L > 1e-12)) continue;
        // ★ shallow AND standing in air. A stretch lying on the lattice is not a
        // bridge, so it is not owed two legs and must not be excised for lacking them.
        if (std::fabs(d.z) / L < std::sqrt(0.5) && !supported_below(pp[i])) {
          if (run == 0) rs = i - 1; run += L;
        } else if (run > 0) close_run(i - 1);
      }
      if (run > 0) close_run(pp.size() - 1);
      // split the polyline at dropped stretches, flags travelling with points
      Poly seg; std::vector<char> segf, sega;
      auto flush2 = [&]() {
        if (seg.pts.size() >= 3) {
          rebuilt.push_back(seg);
          rebuilt_fam.push_back(curve_fam[ci]);
          rebuilt_dsep.push_back(curve_dsep[ci]);
          rebuilt_flat.push_back(segf);
          rebuilt_arch.push_back(sega);
        }
        seg.pts.clear(); segf.clear(); sega.clear();
      };
      for (std::size_t i = 0; i < pp.size(); ++i) {
        if (drop[i]) { flush2(); continue; }
        seg.pts.push_back(pp[i]);
        segf.push_back(curve_flat[ci][i]);
        sega.push_back(curve_arch[ci][i]);
      }
      flush2();
    }
    curves.swap(rebuilt);
    curve_fam.swap(rebuilt_fam);
    curve_dsep.swap(rebuilt_dsep);
    curve_flat.swap(rebuilt_flat);
    curve_arch.swap(rebuilt_arch);
    // ★ a connector that tied INTO an excised stretch would now be a stick to
    // nowhere — a free end by construction. It goes with the stretch it served.
    if (!dropped_pts.empty()) {
      std::vector<std::array<Vec3, 2>> ckeep;
      std::vector<char> lkeep;
      std::vector<double> rkeep;
      std::size_t cdrop = 0;
      for (std::size_t ci2 = 0; ci2 < connectors.size(); ++ci2) {
        const auto& cn = connectors[ci2];
        bool bad = false;
        for (const Vec3& dq : dropped_pts) {
          if (vnorm(vsub(cn[0], dq)) < 0.75 || vnorm(vsub(cn[1], dq)) < 0.75) {
            bad = true; break;
          }
        }
        if (bad) ++cdrop;
        else { ckeep.push_back(cn); lkeep.push_back(conn_level[ci2]);
               rkeep.push_back(conn_r[ci2]); }
      }
      connectors.swap(ckeep);
      conn_level.swap(lkeep);
      conn_r.swap(rkeep);
      std::printf("  (%zu connector(s) into excised stretches removed)\n", cdrop);
    }
    std::printf("TWO-LEG CENSUS r%d: %zu both-legged, %zu self-carrying ARCHES; "
                "%zu one-legged and %zu zero-legged EXCISED so far (%.1f mm)\n",
                srg_round, bridges_two, bridges_arched, bridges_one, bridges_zero,
                excised_mm);
    if (bridges_one + bridges_zero == excised_before) break;   // nothing new: done
  }
  {
    // ★ THE RECOUNT — the claim the MAP makes is measured AFTER the surgery, on the
    // final curve set with the surviving connectors and anchors as legs.
    {
      const double tc = 2.0;
      auto hk = [&](const Vec3& q) {
        return std::array<long long, 3>{(long long)std::floor(q.x / tc),
                                        (long long)std::floor(q.y / tc),
                                        (long long)std::floor(q.z / tc)};
      };
      std::map<std::array<long long, 3>, std::vector<std::pair<Vec3, int>>> H2;
      for (std::size_t ci = 0; ci < curves.size(); ++ci)
        for (const Vec3& q : curves[ci].pts) H2[hk(q)].push_back({q, int(ci)});
      int aux2 = int(curves.size());
      auto add2 = [&](const Vec3& a2, const Vec3& b2) {
        const double L = vnorm(vsub(b2, a2));
        const int m = std::max(1, int(L / 0.5));
        for (int t = 0; t <= m; ++t)
          H2[hk(vadd(a2, vscale(vsub(b2, a2), double(t) / m)))].push_back(
              {vadd(a2, vscale(vsub(b2, a2), double(t) / m)), aux2});
        ++aux2;
      };
      for (const auto& cn : connectors) add2(cn[0], cn[1]);
      for (const auto& an : anchors) add2(an[0], an[1]);
      auto held2 = [&](const Vec3& q, int self) {
        if (q.z <= blo.z + 0.5) return true;
        const auto k0 = hk(q);
        for (long long dz = -1; dz <= 1; ++dz)
          for (long long dy = -1; dy <= 1; ++dy)
            for (long long dx = -1; dx <= 1; ++dx) {
              auto it = H2.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
              if (it == H2.end()) continue;
              for (const auto& pr : it->second) {
                if (pr.second == self) continue;
                if (pr.first.z > q.z + 0.6) continue;
                if (vnorm(vsub(pr.first, q)) <= 1.2) return true;
              }
            }
        return false;
      };
      final_two = 0; final_bad = 0;
      for (std::size_t ci = 0; ci < curves.size(); ++ci) {
        const auto& pp = curves[ci].pts;
        double run = 0; std::size_t rs = 0;
        auto cl = [&](std::size_t re) {
          if (run < 2.0) { run = 0; return; }
          bool arched = false;
          for (std::size_t t = rs; t <= re; ++t)
            if (curve_arch[ci][t]) { arched = true; break; }
          if (arched) { ++final_two; run = 0; return; }   // self-carrying, legal
          const int legs = (held2(pp[rs], int(ci)) ? 1 : 0) +
                           (held2(pp[re], int(ci)) ? 1 : 0);
          if (legs == 2) ++final_two; else ++final_bad;
          run = 0;
        };
        for (std::size_t i = 1; i < pp.size(); ++i) {
          const Vec3 d = vsub(pp[i], pp[i - 1]);
          const double L = vnorm(d); if (!(L > 1e-12)) continue;
          if (std::fabs(d.z) / L < std::sqrt(0.5) && !supported_below(pp[i])) {
            if (run == 0) rs = i - 1; run += L;
          } else if (run > 0) cl(i - 1);
        }
        if (run > 0) cl(pp.size() - 1);
      }
      std::printf("POST-SURGERY RECOUNT: %zu bridges, ALL two-legged: %s "
                  "(%zu still short)\n",
                  final_two, final_bad == 0 ? "YES" : "NO", final_bad);
    }
  }

  // ── COLLECT every solid first, so connectivity can be CHECKED and REPAIRED
  //    before a single triangle is written ─────────────────────────────────────
  struct Solid { Vec3 a, b; double r; char box = 0; };   // a == b means a ball
  std::vector<Solid> solids;
  struct BeamSeg { Vec3 a, b; double r; int ina, inb; };
  std::vector<BeamSeg> beam_segs;
  const double r = 0.5 * strut_d;          // the MINIMUM bead (connectors, anchors)
  const double base_t = 1.2;
  const Vec3 shift{-blo.x, -blo.y, -blo.z + base_t};
  for (std::size_t ci = 0; ci < curves.size(); ++ci) {
    const Poly& c2 = curves[ci];
    // ★ v2: the bead grades with the local cell — thicker strands where cells are
    // big, the production law's own shape (t linear in spacing at fixed density),
    // tempered so an 8 mm cell carries ~1.4x the minimum bead, not 2.7x.
    const double rc = bead_for(curve_dsep[ci]);
    for (std::size_t i = 1; i < c2.pts.size(); ++i) {
      const Vec3 p0 = vadd(c2.pts[i - 1], shift), p1 = vadd(c2.pts[i], shift);
      const char fb = (curve_flat[ci][i - 1] && curve_flat[ci][i]) ? 1 : 0;
      if (vnorm(vsub(p1, p0)) > 1e-9) solids.push_back({p0, p1, rc, fb});
    }
    if (!beam_path.empty())
      for (std::size_t i = 1; i < c2.pts.size(); ++i) {
        const Vec3& a2 = c2.pts[i - 1];
        const Vec3& b2 = c2.pts[i];
        if (vnorm(vsub(b2, a2)) > 1e-9)
          beam_segs.push_back({a2, b2, rc,
                               inside_lattice(a2) ? 1 : 0, inside_lattice(b2) ? 1 : 0});
      }
    // ★★ A NODE BALL ONLY WHERE THE CURVE ACTUALLY TURNS. The coupon emitted an
    // icosahedron at EVERY polyline point — and the RK4 step is 0.21 mm on a 0.8 mm
    // strut, so roughly two balls per bead, hundreds of them piling up wherever
    // points bunch. MEASURED on the printed original: single vertices carrying 384
    // incident triangles, spokes exactly one strut radius — the faceted "triangle"
    // blobs the maintainer spotted, present in the file he printed and therefore
    // never a printability artifact.
    //
    // A ball exists to fill the wedge gap on the OUTSIDE of a bend. Where two
    // consecutive segments are collinear the prisms already meet flush and the ball
    // adds nothing but triangles. Ends always keep theirs (a strut end is a real
    // cap). The SOLID is unchanged — every skipped ball lay entirely inside the
    // union of the two prisms it sat between.
    for (std::size_t i = 0; i < c2.pts.size(); ++i) {
      bool keep = (i == 0 || i + 1 == c2.pts.size());
      if (!keep) {
        const Vec3 a2 = vsub(c2.pts[i], c2.pts[i - 1]);
        const Vec3 b2 = vsub(c2.pts[i + 1], c2.pts[i]);
        const double la = vnorm(a2), lb = vnorm(b2);
        if (la > 1e-9 && lb > 1e-9) {
          const double cosang =
              (a2.x * b2.x + a2.y * b2.y + a2.z * b2.z) / (la * lb);
          keep = cosang < 0.985;            // turns more than ~10 degrees
        } else {
          keep = true;
        }
      }
      if (keep) { const Vec3 p0 = vadd(c2.pts[i], shift); solids.push_back({p0, p0, rc}); }
    }
  }
  for (std::size_t ci2 = 0; ci2 < connectors.size(); ++ci2) {
    const Vec3 p0 = vadd(connectors[ci2][0], shift),
               p1 = vadd(connectors[ci2][1], shift);
    if (vnorm(vsub(p1, p0)) > 1e-9)
      solids.push_back({p0, p1, conn_r[ci2], conn_level[ci2]});
  }
  // ── ★★ THE BEAM SUBMODEL DUMP ────────────────────────────────────────────────
  // Runs HERE, after every strut exists. (It first ran inside the once-only header
  // init, i.e. during curve 0, and rasterised 9 voxels instead of thousands.)
  if (!beam_path.empty()) {
    if (FILE* bf = std::fopen(beam_path.c_str(), "w")) {
      std::fprintf(bf, "GRID %.10g %.10g %.10g %.10g %d %d %d\n",
                   grid.origin.x, grid.origin.y, grid.origin.z, grid.spacing,
                   grid.nx, grid.ny, grid.nz);
      const int NX = grid.nx + 1, NY = grid.ny + 1;
      auto node_xyz = [&](int n, double& x, double& y, double& z) {
        const int i = n % NX, j = (n / NX) % NY, k = n / (NX * NY);
        x = grid.origin.x + i * grid.spacing;
        y = grid.origin.y + j * grid.spacing;
        z = grid.origin.z + k * grid.spacing; };
      double x, y, z;
      for (const DirichletBC& b : setup.bcs) {
        node_xyz(b.node, x, y, z);
        std::fprintf(bf, "BC %.10g %.10g %.10g %d %.10g\n", x, y, z, b.component, b.value);
      }
      for (const NodalLoad& l : setup.options.external_loads) {
        node_xyz(l.node, x, y, z);
        std::fprintf(bf, "LOAD %.10g %.10g %.10g %d %.10g\n", x, y, z, l.component, l.value);
      }
      for (const BeamSeg& bs : beam_segs)
        std::fprintf(bf, "SEG %.8g %.8g %.8g %.8g %.8g %.8g %.6g %d %d\n",
                     bs.a.x, bs.a.y, bs.a.z, bs.b.x, bs.b.y, bs.b.z, bs.r, bs.ina, bs.inb);
      std::fclose(bf);
      std::printf("beam model: %zu segments -> %s\n", beam_segs.size(), beam_path.c_str());
    }
    // ★ THE HYBRID MODEL'S MASKS. Per voxel: bit0 = the part has material here,
    // bit1 = this voxel is inside a declared lattice region (so it is filled with
    // BEAMS, not a hex element). The hybrid meshes hex where bit0 && !bit1 and ties
    // the beam nodes into those elements -- no homogenisation anywhere, and no
    // clamped boundary rotations.
    {
      std::vector<unsigned char> mk(grid.voxel_count(), 0);
      for (std::size_t e = 0; e < grid.voxel_count(); ++e) {
        if (density_full[e] > 0.5) mk[e] |= 1u;
        const int i = int(e % grid.nx), j = int((e / grid.nx) % grid.ny),
                  k = int(e / (std::size_t(grid.nx) * grid.ny));
        const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                     grid.origin.y + (j + 0.5) * grid.spacing,
                     grid.origin.z + (k + 0.5) * grid.spacing};
        if (inside_lattice(c)) mk[e] |= 2u;
      }
      if (FILE* mf = std::fopen((beam_path + ".mask").c_str(), "wb")) {
        std::fwrite(mk.data(), 1, mk.size(), mf); std::fclose(mf);
        std::size_t ns = 0, nl = 0;
        for (unsigned char v : mk) { if (v & 1u) ++ns; if ((v & 1u) && (v & 2u)) ++nl; }
        std::printf("hybrid masks: %zu solid voxels, %zu of them in a lattice region\n", ns, nl);
      }
    }
    // the SOLID-region global field (too stiff; the baseline)
    if (FILE* df = std::fopen((beam_path + ".disp").c_str(), "wb")) {
      std::fwrite(a.displacement_field.data(), sizeof(double),
                  a.displacement_field.size(), df);
      std::fclose(df);
    }
    // ★★ THE SOFTENED GLOBAL SOLVE. The baseline above has the lattice region still
    // SOLID, so every submodel margin taken from it is OPTIMISTIC by a bias that does
    // NOT shrink with refinement. Re-solve with the region carrying the lattice's own
    // MEASURED relative density through the homogenised path.
    //
    // OCTET IS A STAND-IN: the tensor library has no organic topology, and a rotated
    // cubic tensor is not cubic. Octet is stretching-dominant like a lattice traced
    // along principal directions, so its COMPLIANCE MAGNITUDE is the right order; its
    // ANISOTROPY is wrong. Enough to drive a boundary, not to certify.
    const double vvox = grid.spacing * grid.spacing * grid.spacing;
    std::vector<double> vol(grid.voxel_count(), 0.0);
    for (const BeamSeg& bs : beam_segs) {
      const double len = vnorm(vsub(bs.b, bs.a));
      const int nst = std::max(1, int(len / (0.25 * grid.spacing)) + 1);
      const double dv = M_PI * bs.r * bs.r * len / nst;
      for (int t = 0; t < nst; ++t) {
        const double f = (t + 0.5) / nst;
        const Vec3 q{bs.a.x + (bs.b.x - bs.a.x) * f, bs.a.y + (bs.b.y - bs.a.y) * f,
                     bs.a.z + (bs.b.z - bs.a.z) * f};
        const int i = int((q.x - grid.origin.x) / grid.spacing);
        const int j = int((q.y - grid.origin.y) / grid.spacing);
        const int k = int((q.z - grid.origin.z) / grid.spacing);
        if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz) continue;
        vol[grid.index(i, j, k)] += dv;
      }
    }
    const double rlo = lattice_rho_min(LatticeTopology::Octet);
    const double rhi = lattice_rho_max(LatticeTopology::Octet);
    LatticePosture post;
    post.topology = LatticeTopology::Octet;
    post.cell_size_mm = d_min;
    post.mask.assign(grid.voxel_count(), 0);
    post.relative_density.assign(grid.voxel_count(), 0.0);
    std::size_t nlat = 0; double rsum = 0.0;
    for (std::size_t e = 0; e < grid.voxel_count(); ++e) {
      if (density[e] <= 0.5 || vol[e] <= 0.0) continue;
      double rho = vol[e] / vvox;
      if (rho > 1.0) rho = 1.0;
      if (rho < rlo) rho = rlo;              // below the band: use the band floor
      // POSITIVE CONTROL: force one uniform density. At rho 0.90 the octet is only
      // 1.47x softer than solid, so max|u| MUST land near 1.5x the solid answer. If
      // it still blows up, the fault is the MASK, not the densities.
      if (const char* ov = std::getenv("TOPOPT_SOFT_RHO")) rho = std::atof(ov);
      post.mask[e] = 1;
      post.relative_density[e] = std::min(rho, rhi);
      rsum += post.relative_density[e]; ++nlat;
    }
    std::printf("softened global: %zu latticed voxels of %zu, mean rho %.4f "
                "(octet band %.3f..%.3f)\n",
                nlat, grid.voxel_count(), nlat ? rsum / nlat : 0.0, rlo, rhi);
    if (nlat == 0) {
      std::printf("softened global: REFUSING, no latticed voxels\n");
    } else {
      const FixedDesignAnalysis a2 = analyze_fixed_design(
          grid, sp, density, setup.bcs, setup.options.external_loads, mat,
          Vec3{0, 0, 1}, 1e-8, 0, SolverKind::JacobiCG, 1.5, kd, true,
          static_cast<double>(solid), &post);
      if (a2.non_convergent) {
        std::printf("softened global: REFUSING, solve did not converge\n");
      } else if (FILE* d2 = std::fopen((beam_path + ".disp_soft").c_str(), "wb")) {
        std::fwrite(a2.displacement_field.data(), sizeof(double),
                    a2.displacement_field.size(), d2);
        std::fclose(d2);
        double m1 = 0.0, m2 = 0.0;
        for (double v : a.displacement_field) m1 = std::max(m1, std::fabs(v));
        for (double v : a2.displacement_field) m2 = std::max(m2, std::fabs(v));
        std::printf("softened global: max|u| solid %.6g -> softened %.6g "
                    "(%.3fx more compliant)\n", m1, m2, m1 > 0 ? m2 / m1 : 0.0);
      }
    }
  }
  // ★ ANCHORS MUST PENETRATE THE SLAB, NOT KISS IT. The first version ended each
  // anchor at z = base_t, exactly the slab's top surface: a zero-thickness contact,
  // which is NOT a solid union and which a slicer correctly reports as a separate
  // floating body. They now run to z = 0.
  // ★ v2: the anchors were the LAST dead-straight population — the swirl bends the
  // traced curves, but every anchor drops plumb from its curve's low point, and the
  // lower half of the cube reads as fence posts. Each anchor now bows gently along
  // the swirl field: a quadratic bow of at most 12 % of its length (capped 1.5 mm),
  // so the leg stays steeper than ~80 degrees — printability untouched, but the
  // forest reads grown, not extruded.
  for (std::size_t ai = 0; ai < anchors.size(); ++ai) {
    const auto& ap = anchors[ai];
    const double r = anchor_r[ai];          // this leg's own bead
    const Vec3 p0 = vadd(ap[0], shift);
    const Vec3 p3{p0.x, p0.y, 0.0};
    const double L = p0.z;
    if (swirl_amp > 0.0 && L > 4.0) {
      Vec3 sw = swirl_of(ap[0]);
      sw.z = 0.0;
      const double sl = vnorm(sw);
      const double bow = std::min(0.12 * L, 1.5);
      if (sl > 1e-9) {
        sw = vscale(sw, bow / sl);
        Vec3 prev = p0;
        const int NS = 4;
        for (int t2 = 1; t2 <= NS; ++t2) {
          const double u = double(t2) / NS;
          const double b = 4.0 * u * (1.0 - u);          // 0 at ends, 1 mid
          const Vec3 q{p0.x + sw.x * b, p0.y + sw.y * b, p0.z * (1.0 - u)};
          solids.push_back({prev, q, r});
          prev = q;
        }
        continue;
      }
    }
    solids.push_back({p0, p3, r});
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
  // ★ THE RASTER HAS TO FIT IN MEMORY. 0.15 mm voxels over a 40 mm cube is 21 M
  // cells; over a 220 mm part it is 3.2 BILLION. Coarsen only as far as the budget
  // forces, and say so when the pitch gets coarse relative to the thinnest bead —
  // below about a third of the bead the centre-in-radius test starts MISSING thin
  // struts, which would report false floaters and grow spurious repair legs.
  // Both cube sizes stay at exactly 0.15, so their output is unchanged.
  const double rx_mm = bhi.x - blo.x, ry_mm = bhi.y - blo.y,
               rz_mm = bhi.z - blo.z + base_t;
  double vx = 0.15;
  auto raster_cells = [&](double v) {
    return (long double)(rx_mm / v + 4) * (long double)(ry_mm / v + 4) *
           (long double)(rz_mm / v + 6); };
  while (raster_cells(vx) > 6.0e8) vx *= 1.25;
  const double thinnest_bead = 0.5 * strut_d;
  if (vx > 0.15 + 1e-9)
    std::printf("connectivity: raster coarsened to %.3f mm to fit %.0f M cells "
                "(bead %.2f mm, ratio %.2f)%s\n", vx, (double)raster_cells(vx) / 1e6,
                thinnest_bead, vx / thinnest_bead,
                vx > 0.35 * thinnest_bead ? "  ** COARSE: floating counts may be overstated" : "");
  const int RX = int(rx_mm / vx) + 4, RY = int(ry_mm / vx) + 4,
            RZ = int(rz_mm / vx) + 6;
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
  // ★ THE NET. Everything above should already be inside; this says so out loud
  // rather than assuming it, and drops whatever is not. A non-zero count here means
  // some stage still moves geometry off the traced path — worth knowing, not hiding.
  if (!regions.empty()) {
    std::size_t before_n = solids.size(), escaped = 0;
    std::vector<Solid> keep; keep.reserve(before_n);
    for (const Solid& sd : solids) {
      const Vec3 pa{sd.a.x - shift.x, sd.a.y - shift.y, sd.a.z - shift.z};
      const Vec3 pb{sd.b.x - shift.x, sd.b.y - shift.y, sd.b.z - shift.z};
      const Vec3 pm{0.5 * (pa.x + pb.x), 0.5 * (pa.y + pb.y), 0.5 * (pa.z + pb.z)};
      bool ok = true;
      for (const Vec3& q : {pa, pb, pm}) {
        bool in = false;
        for (const FaceRegion& fr : regions)
          if (fr.include && region_contains_point(fr, q)) { in = true; break; }
        if (!in) { ok = false; break; }
      }
      if (ok) keep.push_back(sd); else ++escaped;
    }
    solids.swap(keep);
    std::printf("region net: %zu solids checked, %zu OUTSIDE the declared region "
                "and dropped (%.2f%%)\n", before_n, escaped,
                100.0 * double(escaped) / double(std::max<std::size_t>(1, before_n)));
  }
  // ── ★★ THE PRUNER: SUPPORT FROM BELOW, AND REACH A SECOND SURFACE ──────────
  // Two different defects need two different rules and neither is optional:
  //
  //  (a) A DEAD SPROUT rises out of the weave and stops in mid-air. It is perfectly
  //      buildable — every layer of it rests on the one below — so no support test
  //      will ever object. What is wrong with it is that it goes NOWHERE: it carries
  //      no load because it never reaches a second surface. The cure is topological,
  //      not geometric: erode free ends until nothing is left that does not either
  //      loop back into the weave or land on solid. A strand that dead-ends is eaten
  //      along its whole length; one that ties two places together survives whole.
  //
  //  (b) A FLOATING BRANCH hangs with nothing underneath it. It may be attached at
  //      the top and perfectly well anchored in the finished part, and it still
  //      cannot be printed, because the nozzle would be laying it onto air.
  //
  // Both are settled here on a COARSE raster of its own, so the loop can run to a
  // fixed point cheaply; the fine raster below then re-measures independently and
  // reports what actually survived, which is the number worth trusting.
  if (!regions.empty() && prune_rounds > 0) {
    // ★ THE PRUNER MUST JUDGE AT THE PITCH THE CHECK JUDGES AT. Running it coarse
    // left a band of features the pruner could not resolve and the 0.19 mm check
    // could: 110 k unsupported voxels survived a prune that believed it was done.
    // Same pitch, same verdict, and the residual becomes real signal.
    const double pvx = vx;
    const int PX = int((bhi.x - blo.x) / pvx) + 4;
    const int PY = int((bhi.y - blo.y) / pvx) + 4;
    const int PZ = int((bhi.z - blo.z + base_t) / pvx) + 6;
    const Vec3 plo{-2 * pvx, -2 * pvx, -2 * pvx};
    auto pidx = [&](int i, int j, int k) { return (std::size_t(k) * PY + j) * PX + i; };
    auto part_dens = [&](const Vec3& p) {
      const double fx = (p.x - grid.origin.x) / grid.spacing - 0.5;
      const double fy = (p.y - grid.origin.y) / grid.spacing - 0.5;
      const double fz = (p.z - grid.origin.z) / grid.spacing - 0.5;
      const int i0 = int(std::floor(fx)), j0 = int(std::floor(fy)), k0 = int(std::floor(fz));
      const double tx = fx - i0, ty = fy - j0, tz = fz - k0;
      double acc = 0.0;
      for (int dk = 0; dk < 2; ++dk) for (int dj = 0; dj < 2; ++dj) for (int di = 0; di < 2; ++di) {
        const int i = i0 + di, j = j0 + dj, k = k0 + dk;
        double v = 0.0;
        if (i >= 0 && j >= 0 && k >= 0 && i < grid.nx && j < grid.ny && k < grid.nz)
          v = density0[grid.index(i, j, k)] > 0.5 ? 1.0 : 0.0;
        acc += v * (di ? tx : 1 - tx) * (dj ? ty : 1 - ty) * (dk ? tz : 1 - tz);
      }
      return acc; };
    auto is_ground = [&](const Vec3& q) {                 // q is RASTER space
      const Vec3 p{q.x - shift.x, q.y - shift.y, q.z - shift.z};
      if (part_dens(p) < 0.5) return false;               // outside the part
      bool in_reg = false;
      for (const FaceRegion& fr : regions)
        if (fr.include && region_contains_point(fr, p)) { in_reg = true; break; }
      if (!in_reg) return true;                            // kept solid: ground
      if (rim_mm <= 0.0 || cdist.empty()) return false;
      const int gi = int((p.x - grid.origin.x) / grid.spacing);
      const int gj = int((p.y - grid.origin.y) / grid.spacing);
      const int gk = int((p.z - grid.origin.z) / grid.spacing);
      if (gi < 0 || gj < 0 || gk < 0 || gi >= grid.nx || gj >= grid.ny || gk >= grid.nz) return false;
      return cdist[grid.index(gi, gj, gk)] <= rim_mm; };   // the rim counts as ground

    std::size_t dropped_total = 0;
    for (int round = 0; round < prune_rounds; ++round) {
      std::vector<unsigned char> pocc(std::size_t(PX) * PY * PZ, 0);   // 1 lattice, 2 ground
      for (int k = 0; k < PZ; ++k) for (int j = 0; j < PY; ++j) for (int i = 0; i < PX; ++i) {
        const Vec3 q{plo.x + (i + .5) * pvx, plo.y + (j + .5) * pvx, plo.z + (k + .5) * pvx};
        if (is_ground(q)) pocc[pidx(i, j, k)] = 2;
      }
      auto pstamp = [&](const Solid& sd) {
        const Vec3 ab = vsub(sd.b, sd.a);
        const double L2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z;
        const double pad = sd.r + pvx;
        const int i0 = std::max(0, int((std::min(sd.a.x, sd.b.x) - pad - plo.x) / pvx));
        const int i1 = std::min(PX - 1, int((std::max(sd.a.x, sd.b.x) + pad - plo.x) / pvx));
        const int j0 = std::max(0, int((std::min(sd.a.y, sd.b.y) - pad - plo.y) / pvx));
        const int j1 = std::min(PY - 1, int((std::max(sd.a.y, sd.b.y) + pad - plo.y) / pvx));
        const int k0 = std::max(0, int((std::min(sd.a.z, sd.b.z) - pad - plo.z) / pvx));
        const int k1 = std::min(PZ - 1, int((std::max(sd.a.z, sd.b.z) + pad - plo.z) / pvx));
        for (int k = k0; k <= k1; ++k) for (int j = j0; j <= j1; ++j) for (int i = i0; i <= i1; ++i) {
          const Vec3 q{plo.x + (i + .5) * pvx, plo.y + (j + .5) * pvx, plo.z + (k + .5) * pvx};
          double t = 0.0;
          if (L2 > 1e-18) {
            const Vec3 aq = vsub(q, sd.a);
            t = (aq.x * ab.x + aq.y * ab.y + aq.z * ab.z) / L2;
            t = std::min(1.0, std::max(0.0, t));
          }
          const Vec3 c3{sd.a.x + ab.x * t, sd.a.y + ab.y * t, sd.a.z + ab.z * t};
          if (vnorm(vsub(q, c3)) <= sd.r && !pocc[pidx(i, j, k)]) pocc[pidx(i, j, k)] = 1;
        }
      };
      for (const Solid& sd : solids) pstamp(sd);

      // (a) DEAD ENDS, ON THE GRAPH — not on the voxels. Morphological erosion was
      //     the wrong instrument: it removes voxels with at most one occupied
      //     neighbour, which only fires on a one-voxel-thick skeleton, and a 1.3 mm
      //     strut is several voxels across. It measured NOTHING — 0 eroded, every
      //     round — while the sprouts it was meant to eat sat there untouched.
      //
      //     The real structure is a graph: struts meet at shared endpoints. A strut
      //     with a FREE END — an endpoint no other strut shares, not sitting in solid
      //     — is a leaf, and a leaf goes nowhere. Cutting leaves repeatedly consumes
      //     a dead-ending strand along its WHOLE length, while a strand that ties two
      //     places together has no free end and survives intact. Node balls are
      //     excluded from the degree count deliberately: a ball sits exactly on a
      //     curve's last point, so counting it would make every dead end look joined
      //     to something.
      long long eroded = 0;
      {
        auto key_of = [](const Vec3& p) {
          const long long qx = (long long)std::llround(p.x * 1000.0);
          const long long qy = (long long)std::llround(p.y * 1000.0);
          const long long qz = (long long)std::llround(p.z * 1000.0);
          return (qx * 73856093LL) ^ (qy * 19349663LL) ^ (qz * 83492791LL); };
        std::vector<char> alive(solids.size(), 1), isball(solids.size(), 0);
        for (std::size_t n = 0; n < solids.size(); ++n)
          isball[n] = vnorm(vsub(solids[n].b, solids[n].a)) < 1e-9 ? 1 : 0;
        std::map<long long, std::vector<int>> at;
        std::map<long long, Vec3> pos;
        for (std::size_t n = 0; n < solids.size(); ++n) {
          if (isball[n]) continue;
          const long long ka = key_of(solids[n].a), kb = key_of(solids[n].b);
          at[ka].push_back(int(n)); pos[ka] = solids[n].a;
          at[kb].push_back(int(n)); pos[kb] = solids[n].b;
        }
        std::map<long long, int> deg;
        std::map<long long, char> anchored;
        for (auto& kv : at) {
          deg[kv.first] = int(kv.second.size());
          anchored[kv.first] = is_ground(pos[kv.first]) ? 1 : 0;
        }
        bool changed = true;
        while (changed) {
          changed = false;
          for (std::size_t n = 0; n < solids.size(); ++n) {
            if (!alive[n] || isball[n]) continue;
            const long long ka = key_of(solids[n].a), kb = key_of(solids[n].b);
            if (!((deg[ka] <= 1 && !anchored[ka]) || (deg[kb] <= 1 && !anchored[kb]))) continue;
            alive[n] = 0; ++eroded; changed = true;
            if (--deg[ka] < 0) deg[ka] = 0;
            if (--deg[kb] < 0) deg[kb] = 0;
          }
        }
        for (std::size_t n = 0; n < solids.size(); ++n) {
          if (!isball[n] || !alive[n]) continue;
          auto it = at.find(key_of(solids[n].a));
          if (it == at.end()) { alive[n] = 0; continue; }
          bool any = false;
          for (int m : it->second) if (alive[m]) { any = true; break; }
          if (!any) alive[n] = 0;
        }
        std::vector<Solid> kept; kept.reserve(solids.size());
        for (std::size_t n = 0; n < solids.size(); ++n) if (alive[n]) kept.push_back(solids[n]);
        solids.swap(kept);
        if (eroded) {                       // the raster must reflect the cut
          std::fill(pocc.begin(), pocc.end(), 0);
          for (int k = 0; k < PZ; ++k) for (int j = 0; j < PY; ++j) for (int i = 0; i < PX; ++i) {
            const Vec3 q{plo.x + (i + .5) * pvx, plo.y + (j + .5) * pvx, plo.z + (k + .5) * pvx};
            if (is_ground(q)) pocc[pidx(i, j, k)] = 2;
          }
          for (const Solid& sd : solids) pstamp(sd);
        }
      }

      // (b) BUILDABILITY, bottom-up, same rule the fine check uses.
      std::vector<unsigned char> built(pocc.size(), 0);
      std::vector<int> st;
      int pplate = PZ;                       // same plate rule as the fine check
      for (int k = 0; k < PZ && pplate == PZ; ++k)
        for (int j = 0; j < PY && pplate == PZ; ++j)
          for (int i = 0; i < PX; ++i)
            if (pocc[pidx(i, j, k)]) { pplate = k; break; }
      for (int k = 0; k < PZ; ++k) {
        const std::size_t base = std::size_t(k) * PX * PY;
        for (int j = 0; j < PY; ++j) for (int i = 0; i < PX; ++i) {
          const std::size_t n = base + std::size_t(j) * PX + i;
          if (!pocc[n] || built[n]) continue;
          bool ok = (pocc[n] == 2) || (k <= pplate);
          if (!ok) for (int dj = -1; dj <= 1 && !ok; ++dj) for (int di = -1; di <= 1 && !ok; ++di) {
            const int ii = i + di, jj = j + dj;
            if (ii < 0 || jj < 0 || ii >= PX || jj >= PY) continue;
            if (built[std::size_t(k - 1) * PX * PY + std::size_t(jj) * PX + ii]) ok = true;
          }
          if (!ok) continue;
          built[n] = 1; st.push_back(int(n));
          while (!st.empty()) {
            const int m = st.back(); st.pop_back();
            const int mi = m % PX, mj = (m / PX) % PY;
            const int ddi[4] = {1,-1,0,0}, ddj[4] = {0,0,1,-1};
            for (int d = 0; d < 4; ++d) {
              const int ii = mi + ddi[d], jj = mj + ddj[d];
              if (ii < 0 || jj < 0 || ii >= PX || jj >= PY) continue;
              const std::size_t qq = base + std::size_t(jj) * PX + ii;
              if (pocc[qq] && !built[qq]) { built[qq] = 1; st.push_back(int(qq)); }
            }
          }
        }
      }

      // Verdict back onto the struts: sample along each one; any condemned sample
      // condemns the strut, because half a strut is not a thing we can emit.
      // ★ CONDEMN ON THE CENTRELINE, and only the centreline. 90 % of what the build
      // check calls unsupported is the bottom SLIVER of a near-level strut, which is
      // ordinary bridging — but those slivers are SURFACE voxels and the samples here
      // are centreline, so they were never in play. Adding an "open sky" test to
      // spare bridges therefore spared everything: a centreline voxel always has the
      // upper half of its own strut overhead, so the test could never fire, 0 struts
      // were dropped, and real floaters TRIPLED (11 092 -> 32 120). The plain
      // buildability of the centreline is the right discriminator.
      auto condemned = [&](const Vec3& p) {
        const int i = int((p.x - plo.x) / pvx), j = int((p.y - plo.y) / pvx), k = int((p.z - plo.z) / pvx);
        if (i < 0 || j < 0 || k < 0 || i >= PX || j >= PY || k >= PZ) return true;
        const std::size_t n = pidx(i, j, k);
        return pocc[n] == 0 || !built[n]; };
      std::vector<Solid> keep2; keep2.reserve(solids.size());
      std::size_t dropped = 0;
      for (const Solid& sd : solids) {
        bool bad = false;
        for (int t = 0; t <= 4 && !bad; ++t) {
          const double u = t / 4.0;
          bad = condemned(Vec3{sd.a.x + (sd.b.x - sd.a.x) * u,
                               sd.a.y + (sd.b.y - sd.a.y) * u,
                               sd.a.z + (sd.b.z - sd.a.z) * u});
        }
        if (bad) ++dropped; else keep2.push_back(sd);
      }
      solids.swap(keep2);
      dropped_total += dropped + std::size_t(eroded);   // BOTH cuts, not just one
      std::printf("prune r%d @ %.2f mm: %lld DEAD-END struts cut, %zu UNBUILDABLE "
                  "dropped (%zu left)\n", round, pvx, eroded, dropped, solids.size());
      if (dropped == 0 && eroded == 0) break;
    }
    std::printf("prune: %zu struts removed in total (dead ends + unbuildable)\n",
                dropped_total);
  }

  for (const Solid& sd : solids) stamp(sd);
  // the slab — ★ COUPON ONLY. It is a print adapter for a wall cut out of a part.
  // Under a finished part it would be a box_mm-square sheet of plastic, so part-fit
  // emits none and the lattice stands on its own anchor feet.
  if (!fit_part) {
    for (int k = 0; k < RZ; ++k) for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
      const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
      if (q.z >= 0 && q.z <= base_t && q.x >= 0 && q.x <= box_mm && q.y >= 0 && q.y <= box_mm)
        occ[ridx(i, j, k)] = 1;
    }
  }

  // ★ WITHOUT THE COUPON SLAB, "reaches the plate" NO LONGER MEANS "one body".
  // The slab welded every foot together, so a single flood from it proved the piece
  // was one solid. A part-fit run stands on its own separate feet, and two halves
  // that both touch the bed would BOTH flood clean while the file holds two bodies
  // — and the welded writer keeps only the largest, i.e. silently deletes one. So
  // count the distinct ground-connected components and report them.
  int ground_comps = 0;
  // Trilinear on the unmasked part: marching cubes over a hard voxel stamp would
  // give the kept solid a 1.7 mm stair-stepped skin, so sample the iso-surface.
  auto part_density_at = [&](const Vec3& p) -> double {
    const double fx = (p.x - grid.origin.x) / grid.spacing - 0.5;
    const double fy = (p.y - grid.origin.y) / grid.spacing - 0.5;
    const double fz = (p.z - grid.origin.z) / grid.spacing - 0.5;
    const int i0 = int(std::floor(fx)), j0 = int(std::floor(fy)), k0 = int(std::floor(fz));
    const double tx = fx - i0, ty = fy - j0, tz = fz - k0;
    double acc = 0.0;
    for (int dk = 0; dk < 2; ++dk) for (int dj = 0; dj < 2; ++dj) for (int di = 0; di < 2; ++di) {
      const int i = i0 + di, j = j0 + dj, k = k0 + dk;
      double v = 0.0;
      if (i >= 0 && j >= 0 && k >= 0 && i < grid.nx && j < grid.ny && k < grid.nz)
        v = density0[grid.index(i, j, k)] > 0.5 ? 1.0 : 0.0;
      acc += v * (di ? tx : 1 - tx) * (dj ? ty : 1 - ty) * (dk ? tz : 1 - tz);
    }
    return acc; };

  // ── ★ THE SOLID RIM: grade to solid where the region meets KEPT MATERIAL ────
  // Every raster voxel that lies in lattice material and within rim_mm of the solid
  // the job is keeping becomes solid. The lattice then does not end in mid-air at
  // the region edge — it thickens into the wall that holds it. The region's OPEN
  // faces are untouched, so the lattice you look at stays open.
  long long rim_voxels = 0, solid_voxels = 0;
  std::vector<unsigned char> is_rim, in_part;
  if (emit_solid && solid_from_cad && !regions.empty() && !model.mesh.empty()) {
    // ── ★ THE PART'S OWN WALLS, FROM THE STEP ────────────────────────────────
    // Parity fill down each raster column: every triangle of the CAD tessellation
    // deposits the z of its plane into the columns its XY projection covers; sorting
    // each column and filling between consecutive pairs reproduces the solid exactly,
    // because the tessellation is closed. The inclusive edge test is deliberate — a
    // sample landing on a shared edge is then counted by BOTH triangles, which leaves
    // a zero-length span and preserves parity, where a strict test would drop the hit
    // and punch a pinhole column straight through the part.
    is_rim.assign(occ.size(), 0);
    // ★ MUST be allocated before the parity fill writes into it. An earlier patch
    // lost this line while keeping the write, which is an out-of-bounds store into a
    // zero-length vector — and, because `in_part.empty()` then stayed true, the rim
    // silently fell back to the 1.71 mm grid and the output came back BYTE-IDENTICAL.
    in_part.assign(occ.size(), 0);
    std::vector<std::pair<int, float>> hits;
    const auto& V = model.mesh.vertices;
    for (const auto& tri : model.mesh.triangles) {
      const Vec3 a = vadd(V[tri[0]], shift), b = vadd(V[tri[1]], shift), c = vadd(V[tri[2]], shift);
      const double e0x = b.x - a.x, e0y = b.y - a.y, e1x = c.x - a.x, e1y = c.y - a.y;
      const double det = e0x * e1y - e0y * e1x;
      if (std::fabs(det) < 1e-15) continue;              // edge-on: no column crosses it
      const int i0 = std::max(0, int((std::min(a.x, std::min(b.x, c.x)) - rlo.x) / vx) - 1);
      const int i1 = std::min(RX - 1, int((std::max(a.x, std::max(b.x, c.x)) - rlo.x) / vx) + 1);
      const int j0 = std::max(0, int((std::min(a.y, std::min(b.y, c.y)) - rlo.y) / vx) - 1);
      const int j1 = std::min(RY - 1, int((std::max(a.y, std::max(b.y, c.y)) - rlo.y) / vx) + 1);
      for (int j = j0; j <= j1; ++j) for (int i = i0; i <= i1; ++i) {
        const double px = rlo.x + (i + .5) * vx - a.x, py = rlo.y + (j + .5) * vx - a.y;
        const double u = (px * e1y - py * e1x) / det;
        const double w2 = (e0x * py - e0y * px) / det;
        if (u < 0.0 || w2 < 0.0 || u + w2 > 1.0) continue;   // inclusive on every edge
        hits.push_back({j * RX + i, float(a.z + u * (b.z - a.z) + w2 * (c.z - a.z))});
      }
    }
    std::sort(hits.begin(), hits.end());
    std::size_t p = 0;
    while (p < hits.size()) {
      std::size_t q = p;
      while (q < hits.size() && hits[q].first == hits[p].first) ++q;
      const int col = hits[p].first, i = col % RX, j = col / RX;
      for (std::size_t t = p; t + 1 < q; t += 2) {
        const int k0 = std::max(0, int((hits[t].second - rlo.z) / vx));
        const int k1 = std::min(RZ - 1, int((hits[t + 1].second - rlo.z) / vx));
        for (int k = k0; k <= k1; ++k) {
          const Vec3 qz{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
          const Vec3 pp{qz.x - shift.x, qz.y - shift.y, qz.z - shift.z};
          const std::size_t n = ridx(i, j, k);
          in_part[n] = 1;                     // inside the CAD, region or not
          bool in_region = false;
          for (const FaceRegion& fr : regions)
            if (fr.include && region_contains_point(fr, pp)) { in_region = true; break; }
          if (in_region) continue;                      // that volume is the lattice's
          if (!occ[n]) ++solid_voxels;
          occ[n] = 1; is_rim[n] = 1;
        }
      }
      p = q;
    }
    std::printf("solid: %lld voxels from the STEP TESSELLATION (%zu triangles, "
                "%zu column hits) at %.3f mm — not the %.2f mm voxel grid\n",
                solid_voxels, model.mesh.triangles.size(), hits.size(), vx, grid.spacing);
  } else if (emit_solid && !regions.empty()) {
    // THE KEPT SOLID. Everything the job is not latticing, written as part of the
    // same body — so the output is the part, and "supported" means "held by the
    // part", which is the only support statement that means anything here.
    is_rim.assign(occ.size(), 0);
    for (int k = 0; k < RZ; ++k) for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
      const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
      const Vec3 p{q.x - shift.x, q.y - shift.y, q.z - shift.z};
      const int gi = int((p.x - grid.origin.x) / grid.spacing);
      const int gj = int((p.y - grid.origin.y) / grid.spacing);
      const int gk = int((p.z - grid.origin.z) / grid.spacing);
      if (gi < 0 || gj < 0 || gk < 0 || gi >= grid.nx || gj >= grid.ny || gk >= grid.nz) continue;
      if (density[grid.index(gi, gj, gk)] > 0.5) continue;      // that is lattice, not solid
      if (part_density_at(p) < 0.5) continue;                    // outside the part
      const std::size_t n = ridx(i, j, k);
      if (!occ[n]) ++solid_voxels;
      occ[n] = 1; is_rim[n] = 1;
    }
    std::printf("solid: %lld voxels of KEPT PART written alongside the lattice "
                "(the file is the part, not just the weave)\n", solid_voxels);
  }
  // ── ★ THE RIM, GROWN AT RASTER PITCH ────────────────────────────────────────
  // cdist is a chamfer on the 1.71 mm FEA grid, so a rim derived from it steps in
  // 1.71 mm jumps — the staircase along the cradle band, sitting next to a solid
  // that now comes from the CAD at 0.19 mm. When the solid has been stamped we can
  // do far better: breadth-first dilation OUT of the solid, through lattice
  // material, at the raster's own pitch. Same rim, an order of magnitude smoother.
  if (rim_mm > 0.0 && !is_rim.empty()) {
    const int steps = std::max(1, int(rim_mm / vx));
    std::vector<int> frontier, next;
    std::vector<unsigned char> seen_r(occ.size(), 0);
    for (int k = 0; k < RZ; ++k) for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
      const std::size_t n = ridx(i, j, k);
      if (!is_rim[n]) continue;
      seen_r[n] = 1; frontier.push_back(int(n));
    }
    // ★ THE RIM'S EDGE MUST FOLLOW THE CAD, NOT THE 1.71 mm GRID. Asking the density
    // field "is this the lattice region?" quantises the rim's outer edge to the FEA
    // voxel — a stepped band running right alongside a solid that is now CAD-smooth,
    // visible along the cradle. Inside-the-part now comes from the parity fill at
    // raster pitch and inside-the-region is analytic, so both edges of the rim land
    // where the geometry actually is.
    auto in_lattice_raster = [&](int i, int j, int k) {
      const std::size_t n = ridx(i, j, k);
      const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
      const Vec3 p{q.x - shift.x, q.y - shift.y, q.z - shift.z};
      if (!in_part.empty()) {
        if (!in_part[n]) return false;
        for (const FaceRegion& fr : regions)
          if (fr.include && region_contains_point(fr, p)) return true;
        return false;
      }
      const int gi = int((p.x - grid.origin.x) / grid.spacing);
      const int gj = int((p.y - grid.origin.y) / grid.spacing);
      const int gk = int((p.z - grid.origin.z) / grid.spacing);
      if (gi < 0 || gj < 0 || gk < 0 || gi >= grid.nx || gj >= grid.ny || gk >= grid.nz) return false;
      return density[grid.index(gi, gj, gk)] > 0.5; };
    for (int st = 0; st < steps && !frontier.empty(); ++st) {
      next.clear();
      for (int n : frontier) {
        const int i = n % RX, j = (n / RX) % RY, k = n / (RX * RY);
        const int di[6] = {1,-1,0,0,0,0}, dj[6] = {0,0,1,-1,0,0}, dk[6] = {0,0,0,0,1,-1};
        for (int d = 0; d < 6; ++d) {
          const int ii = i + di[d], jj = j + dj[d], kk = k + dk[d];
          if (ii < 0 || jj < 0 || kk < 0 || ii >= RX || jj >= RY || kk >= RZ) continue;
          const std::size_t m = ridx(ii, jj, kk);
          if (seen_r[m]) continue;
          if (!in_lattice_raster(ii, jj, kk)) continue;   // never grow outside the region
          seen_r[m] = 1;
          if (!occ[m]) ++rim_voxels;
          occ[m] = 1; is_rim[m] = 1;
          next.push_back(int(m));
        }
      }
      frontier.swap(next);
    }
    std::printf("rim: %lld voxels grown %d steps (%.2f mm) out of the solid at "
                "%.3f mm pitch — not the %.2f mm grid\n",
                rim_voxels, steps, steps * vx, vx, grid.spacing);
  } else if (rim_mm > 0.0 && !cdist.empty()) {
    if (is_rim.empty()) is_rim.assign(occ.size(), 0);
    for (int k = 0; k < RZ; ++k) for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
      const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
      const Vec3 p{q.x - shift.x, q.y - shift.y, q.z - shift.z};   // back to part space
      const int gi = int((p.x - grid.origin.x) / grid.spacing);
      const int gj = int((p.y - grid.origin.y) / grid.spacing);
      const int gk = int((p.z - grid.origin.z) / grid.spacing);
      if (gi < 0 || gj < 0 || gk < 0 || gi >= grid.nx || gj >= grid.ny || gk >= grid.nz) continue;
      const std::size_t e = grid.index(gi, gj, gk);
      if (density[e] <= 0.5) continue;                 // only inside the lattice region
      if (cdist[e] > rim_mm) continue;                 // only near the kept solid
      const std::size_t n = ridx(i, j, k);
      if (!occ[n]) ++rim_voxels;
      occ[n] = 1; is_rim[n] = 1;
    }
    std::printf("rim: %lld voxels welded solid within %.2f mm of the kept material\n",
                rim_voxels, rim_mm);
  }

  auto flood_from_slab = [&](std::vector<unsigned char>& seen) {
    seen.assign(occ.size(), 0);
    ground_comps = 0;
    std::vector<int> stack;
    for (int k = 0; k < RZ; ++k) for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
      const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
      if (!occ[ridx(i, j, k)]) continue;
      // ★ WHAT COUNTS AS GROUND. A coupon stands on the plate, so ground is the slab.
      // A lattice EMBEDDED in a part is held by the part, so ground is the solid rim
      // — and "floating" then means "this strut reaches nothing that holds it",
      // which is the question that actually matters here.
      const bool grounded = is_rim.empty() ? (q.z >= 0 && q.z <= base_t)
                                           : (is_rim[ridx(i, j, k)] != 0);
      if (!grounded) continue;
      if (seen[ridx(i, j, k)]) continue;
      ++ground_comps;
      seen[ridx(i, j, k)] = 1; stack.push_back(int(ridx(i, j, k)));
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
    }
  };

  // ── ★★ THE CLEANSE: NOTHING MAY LIE OUTSIDE THE PART ────────────────────────
  // The region net earlier samples three points along each strut's CENTRELINE and
  // tests region membership. That misses two things, and both are visible in the
  // slicer as specks on the outside of the wall and stubs under the floor:
  //   * BEAD RADIUS. A region's outer boundary IS the part's face, so a curve traced
  //     at s = 0 sits exactly on the surface with half its bead outside the solid.
  //     A centreline test can never see that.
  //   * Everything the surgery MOVES afterwards — arches lifted off the traced path,
  //     ties, repair legs — none of which the net re-examines.
  // The CAD interior is already rasterised at 0.19 mm for the solid, so the honest
  // fix is a clip against it at the very end: any occupied voxel outside the part is
  // simply not part of the part. Cutting a strut flush leaves the marching cubes to
  // close it against the surface, so the body stays watertight.
  long long clipped = 0;
  // ★ ALWAYS, whenever there is a part to be outside of. When the CAD parity fill has
  // run, `in_part` is the part at raster pitch and is exact. When it has not (no
  // solid emitted), fall back to the trilinear part field so the clip still happens —
  // this is a correctness pass, not a rendering option, and it must not quietly
  // switch itself off because some unrelated flag was cleared.
  if (!regions.empty()) {
    for (int k = 0; k < RZ; ++k) for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
      const std::size_t n = ridx(i, j, k);
      if (!occ[n]) continue;
      bool inside;
      if (!in_part.empty()) {
        inside = in_part[n] != 0;
      } else {
        const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
        inside = part_density_at(Vec3{q.x - shift.x, q.y - shift.y, q.z - shift.z}) >= 0.5;
      }
      if (!inside) { occ[n] = 0; ++clipped; }
    }
    std::printf("cleanse: %lld voxels cut outside the part (%.2f mm^3) — bead "
                "overhang at the faces and anything the surgery moved out\n",
                clipped, clipped * vx * vx * vx);
  }

  std::vector<unsigned char> seen;
  long long floating0 = 0;
  flood_from_slab(seen);
  for (std::size_t n = 0; n < occ.size(); ++n) if (occ[n] && !seen[n]) ++floating0;
  std::printf("connectivity: raster %dx%dx%d @ %.2f mm  floating voxels BEFORE repair: %lld"
              "  ground components: %d\n", RX, RY, RZ, vx, floating0, ground_comps);

  // ── REPAIR: tie each floating component to the ground with a vertical leg,
  //    then re-flood. Repeat until nothing floats or no progress is made. ───────
  int repair_rounds = 0; long long added = 0;
  // ★ A vertical leg to z = 0 reconnects a coupon to its plate. Inside a part it
  // would be a strut driven down through solid material that is not ours to touch,
  // so an embedded run reports the disconnection instead of "fixing" it.
  const int repair_cap = is_rim.empty() ? 12 : 0;
  for (; repair_rounds < repair_cap; ++repair_rounds) {
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
  // ── ★★ SUPPORT COMES FROM BELOW ─────────────────────────────────────────────
  // Grounding on the rim says a strut reaches something that HOLDS it. It does not
  // say the printer can build it: a strut hanging off rim that is ABOVE it is held
  // in the finished part and unbuildable on the way there. That distinction was lost
  // when the coupon's "reaches the plate" test was replaced, and it is exactly the
  // strut that comes down from the top with nothing under it.
  //
  // So sweep the raster bottom-up, one layer at a time. A voxel is buildable if it
  // is part solid, or it has a buildable voxel among the nine directly beneath it,
  // or it is joined WITHIN its own layer to something that does — the last clause is
  // what keeps a genuine bridge legal while a mid-air start is not.
  long long unsupported = 0, unsupported_lattice = 0;
  {
    std::vector<unsigned char> built(occ.size(), 0);
    std::vector<int> st;
    // ★ THE PLATE IS THE LOWEST OCCUPIED LAYER, NOT LAYER ZERO. The raster starts
    // two voxels BELOW the part, so `k == 0` is empty air and nothing ever seeded
    // from the bed: lattice resting directly on the plate was being counted as
    // hanging in mid-air. That mis-seeding was the largest unsupported cluster in
    // the part (8587 voxels at z = 2.0 mm — sitting on the bed).
    int plate_k = RZ;
    for (int k = 0; k < RZ && plate_k == RZ; ++k)
      for (int j = 0; j < RY && plate_k == RZ; ++j)
        for (int i = 0; i < RX; ++i)
          if (occ[ridx(i, j, k)]) { plate_k = k; break; }
    for (int k = 0; k < RZ; ++k) {
      const std::size_t base = std::size_t(k) * RX * RY;
      for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
        const std::size_t n = base + std::size_t(j) * RX + i;
        if (!occ[n] || built[n]) continue;
        bool ok = (is_rim.empty() ? false : is_rim[n] != 0);
        if (!ok && k <= plate_k) ok = true;
        if (!ok && k > 0) {
          for (int dj = -1; dj <= 1 && !ok; ++dj) for (int di = -1; di <= 1 && !ok; ++di) {
            const int ii = i + di, jj = j + dj;
            if (ii < 0 || jj < 0 || ii >= RX || jj >= RY) continue;
            if (built[std::size_t(k - 1) * RX * RY + std::size_t(jj) * RX + ii]) ok = true;
          }
        }
        if (!ok) continue;
        built[n] = 1; st.push_back(int(n));
        while (!st.empty()) {                       // spread within THIS layer only
          const int m = st.back(); st.pop_back();
          const int mi = m % RX, mj = (m / RX) % RY;
          const int ddi[4] = {1,-1,0,0}, ddj[4] = {0,0,1,-1};
          for (int d = 0; d < 4; ++d) {
            const int ii = mi + ddi[d], jj = mj + ddj[d];
            if (ii < 0 || jj < 0 || ii >= RX || jj >= RY) continue;
            const std::size_t q = base + std::size_t(jj) * RX + ii;
            if (occ[q] && !built[q]) { built[q] = 1; st.push_back(int(q)); }
          }
        }
      }
    }
    for (std::size_t n = 0; n < occ.size(); ++n)
      if (occ[n] && !built[n]) {
        ++unsupported;
        if (is_rim.empty() || !is_rim[n]) ++unsupported_lattice;
      }
    // ★ WHAT ARE THEY? A diffuse 2 % spread over every strut's underside is a
    // rasterisation artefact and means the check is too strict; a handful of fat
    // clusters is real unbuildable structure and means the pruner is missing it.
    // The two call for opposite responses, so cluster them before concluding.
    {
      std::vector<unsigned char> vis(occ.size(), 0);
      std::vector<int> stack2, sizes;
      int biggest_i = 0, biggest_j = 0, biggest_k = 0; long long biggest = 0;
      for (std::size_t n0 = 0; n0 < occ.size(); ++n0) {
        if (!occ[n0] || built[n0] || vis[n0]) continue;
        if (!is_rim.empty() && is_rim[n0]) continue;
        long long sz = 0; stack2.clear(); stack2.push_back(int(n0)); vis[n0] = 1;
        const int si = int(n0) % RX, sj = (int(n0) / RX) % RY, sk = int(n0) / (RX * RY);
        while (!stack2.empty()) {
          const int m = stack2.back(); stack2.pop_back(); ++sz;
          const int i = m % RX, j = (m / RX) % RY, k = m / (RX * RY);
          for (int dk = -1; dk <= 1; ++dk) for (int dj = -1; dj <= 1; ++dj) for (int di = -1; di <= 1; ++di) {
            const int ii = i + di, jj = j + dj, kk = k + dk;
            if (ii < 0 || jj < 0 || kk < 0 || ii >= RX || jj >= RY || kk >= RZ) continue;
            const std::size_t q = ridx(ii, jj, kk);
            if (occ[q] && !built[q] && !vis[q] && (is_rim.empty() || !is_rim[q])) {
              vis[q] = 1; stack2.push_back(int(q));
            }
          }
        }
        sizes.push_back(int(sz));
        if (sz > biggest) { biggest = sz; biggest_i = si; biggest_j = sj; biggest_k = sk; }
      }
      // ★ ARE THESE FLOATING BRANCHES, OR THE UNDERSIDES OF ROUND STRUTS? A strut
      // laid nearly level has a bottom sliver that narrows to nothing, so its lowest
      // voxels sit under their own strut with air beneath — the very defect the flat
      // box ties were introduced to cure, and precisely what a slicer bridges every
      // day. It is distinguishable from a genuinely floating branch by ONE question:
      // is there material directly overhead? A sliver has its own strut above it; a
      // floating branch has open sky.
      long long with_roof = 0, open_sky = 0;
      for (std::size_t n0 = 0; n0 < occ.size(); ++n0) {
        if (!occ[n0] || built[n0]) continue;
        if (!is_rim.empty() && is_rim[n0]) continue;
        const int i = int(n0) % RX, j = (int(n0) / RX) % RY, k = int(n0) / (RX * RY);
        bool roof = false;
        const int lim = std::min(RZ - 1, k + int(2.0 / vx));
        for (int kk = k + 1; kk <= lim && !roof; ++kk)
          if (occ[ridx(i, j, kk)]) roof = true;
        if (roof) ++with_roof; else ++open_sky;
      }
      std::printf("unsupported kind: %lld under their OWN strut (bridgeable sliver), "
                  "%lld with OPEN SKY above (a real floating branch) — %.1f%% sliver\n",
                  with_roof, open_sky,
                  100.0 * double(with_roof) / double(std::max(1LL, with_roof + open_sky)));
      std::sort(sizes.begin(), sizes.end());
      const double vmm3 = vx * vx * vx;
      std::printf("unsupported shape: %zu clusters; median %d vox, p90 %d, LARGEST %lld "
                  "(%.1f mm^3) at (%.1f, %.1f, %.1f)\n",
                  sizes.size(),
                  sizes.empty() ? 0 : sizes[sizes.size() / 2],
                  sizes.empty() ? 0 : sizes[std::min(sizes.size() - 1, sizes.size() * 9 / 10)],
                  biggest, biggest * vmm3,
                  rlo.x + (biggest_i + .5) * vx, rlo.y + (biggest_j + .5) * vx,
                  rlo.z + (biggest_k + .5) * vx);
    }
    std::printf("build check (bottom-up, support from BELOW): %lld unsupported voxels"
                " (%lld of them lattice, %.3f%% of the body)\n",
                unsupported, unsupported_lattice,
                100.0 * double(unsupported) /
                    double(std::max<std::size_t>(1, std::count(occ.begin(), occ.end(), 1))));
  }

  long long floating1 = 0;
  for (std::size_t n = 0; n < occ.size(); ++n) if (occ[n] && !seen[n]) ++floating1;
  std::printf("repair: %lld legs added over %d rounds  floating voxels AFTER: %lld  %s\n",
              added, repair_rounds, floating1,
              floating1 == 0 ? "-> ONE CONNECTED BODY" : "-> STILL FLOATING");

  // ★ AND SWEEP UP WHAT IS LEFT. These are specks that reach no rim and no plate —
  // mostly the tail end of a strut the cleanse severed, because the piece that was
  // holding it on was the piece sticking out of the part. The welded writer already
  // discards them when it keeps the largest component, but relying on that means the
  // reported "floating" count describes geometry the file does not contain. Delete
  // them here instead, so the number and the STL agree.
  if (!is_rim.empty() && floating1 > 0) {
    long long swept = 0;
    for (std::size_t n = 0; n < occ.size(); ++n)
      if (occ[n] && !seen[n]) { occ[n] = 0; ++swept; }
    long long recheck = 0;
    for (std::size_t n = 0; n < occ.size(); ++n) if (occ[n] && !seen[n]) ++recheck;
    std::printf("sweep: %lld floating voxels removed (%.3f mm^3) — floating now %lld\n",
                swept, swept * vx * vx * vx, recheck);
  }
  if (floating1 != 0 && is_rim.empty()) {
    std::fprintf(stderr, "REFUSING: %lld voxels still float; a coupon that fails for\n"
                         "disconnection tests nothing about flowing lattices.\n", floating1);
    return 3;
  }
  if (floating1 != 0)
    std::printf("             ** %lld voxels (%.2f%% of the lattice) reach NO solid rim —\n"
                "                struts the surrounding walls do not hold.\n", floating1,
                100.0 * double(floating1) /
                    double(std::max<long long>(1, std::count(occ.begin(), occ.end(), 1))));

  // ── mesh it ─────────────────────────────────────────────────────────────────
  MeshSink sink;
  if (!fit_part) {                      // ★ coupon slab only — see the raster above
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
    else if (sd.box) { emit_box_tie(sink, sd.a, sd.b, sd.r); ++nseg_emitted; }
    else { emit_strut(sink, sd.a, sd.b, sd.r, 8); ++nseg_emitted; }
  }
  // guarded on emit_welded too: with no welded body nothing else would write the
  // requested filename, and the run would silently produce no file by that name.
  const std::string soup_out =
      (emit_solid && !regions.empty() && emit_welded)
          ? out.substr(0, out.find_last_of('.')) + "_STRUTS_DIAGNOSTIC.stl"
          : out;
  write_stl_file(soup_out, sink.mesh);

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
  if (!emit_welded) {
    std::printf("welded body: SKIPPED (emit_welded=0) — soup written, raster checks ran\n");
  } else {
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
    // ★ NAME THE COMPLETE PART AS THE OUTPUT. On a region run the soup is struts
    // ONLY — it holds no CAD solid, because the solid is stamped into the raster and
    // exists solely in this marching-cubes body. Writing the soup under the plain
    // name made the one file that is NOT the part look like the deliverable, and it
    // opens as a lattice floating in space with no model around it.
    const bool solid_in_welded = emit_solid && !regions.empty() && emit_welded;
    const std::string wout = solid_in_welded
        ? out
        : out.substr(0, out.find_last_of('.')) + "_WELDED.stl";
    write_stl_file(wout, welded);
    if (ground_comps > 1)
      std::printf("welded body: ** %d SEPARATE %s — the welded file keeps only the\n"
                  "             LARGEST. The soup file has all of it.\n", ground_comps,
                  is_rim.empty() ? "BODIES STAND ON THE PLATE"
                                 : "RIM-CONNECTED GROUPS (the rim itself is in pieces)");
    std::printf("welded body: %zu tris (was %zu, %d comps -> %d), watertight=%s\n"
                "             sealed cavities filled: %d\n             -> %s  <<< THE PART\n",
                welded.triangles.size(), before_tris, comps_raw, comps2,
                wt.watertight ? "YES" : "no", comps_raw - 1, wout.c_str());
  }

  std::FILE* mf = std::fopen(mapp.c_str(), "w");
  // ★ RECORD THE EXACT INVOCATION. Every deliverable so far names its settings only
  // in prose, so re-deriving which flags produced which cube meant reading run logs
  // that do not echo half of them. The command line is the recipe; write it down.
  std::fprintf(mf,
    "GRADED (FLOWING) LATTICE — traced from the maintainer's own stress field\n"
    "================================================================================\n");
  std::fprintf(mf, "command          :");
  for (int ai2 = 0; ai2 < argc; ++ai2) std::fprintf(mf, " %s", argv[ai2]);
  std::fprintf(mf, "\n");
  std::fprintf(mf,
    "job              : %s\n  peak von Mises : %.10g MPa (reproduces the production analyze run)\n"
    "sub-box          : %.1f mm span at part centroid (%.1f, %.1f, %.1f)\n"
    "spacing d_sep    : %.2f-%.2f mm graded (Jobard & Lefer / Curvy)\n"
    "one-leg trim     : %.1f mm removed\n"
    "TWO-LEG CENSUS   : %zu both / %zu one / %zu zero-legged (short ones EXCISED)\n"
    "printability     : %s\n"
    "POST-SURGERY     : %zu bridges, %zu short — ALL TWO-LEGGED: %s\n"
    "strut diameter   : %.2f mm at the %.1f mm cell, scaling^%.2f with cell size\n"
    "curves placed    : %zu  (all three principal families)\n"
    "  connectors      : %zu\n  base anchors    : %zu\n  repair legs     : %lld\n"
    "  FLOATING VOXELS : %lld  (rasterised check, 0 = one connected body)\n"
    "  segments        : %llu\n  triangles       : %zu\n\n"
    "TRACED ARC LENGTH\n  total            : %.1f mm\n"
    "  beyond 45 deg    : %.1f mm  (%.1f %%)\n\n"
    "UNSUPPORTED HORIZONTAL RUNS  (contiguous arc beyond 45 deg)\n"
    "  ★ UPPER BOUND: ignores support a crossing curve may give from below.\n"
    "  count            : %zu\n",
    job_path.c_str(), peak, part_span, c.x, c.y, c.z, d_min, d_max,
    trimmed_mm, bridges_two, bridges_one, bridges_zero,
    enforce_print ? "ENFORCED (easier printing: ribbons, arches, two-leg surgery)"
                  : "RAW (as traced; census reports, nothing reshaped or cut)",
    final_two, final_bad, final_bad == 0 ? "YES" : "NO", strut_d, d_min,
    bead_pow,
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
