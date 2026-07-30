// lattice_boundary_probe.cpp — measurement harness (NOT a CI test) for the
// lattice boundary finish (handoff 2026-07-29-lattice-boundary-finish).
//
// MEASUREMENT ONLY: generates the evidence part with the REAL production
// generator and measures the bars B2/B4/B5/B6/B8/B9/B10 from the EMITTED
// geometry — numbers, not assertions. The "before" mode reproduces the old
// behaviour (cell-CENTRE activation, whole struts, no skin) for the
// before/after table.
//
// EVIDENCE PART (all analytic — the shared predicate is evaluated exactly):
//   * plate 48 x 32 x 16 mm (straight edges),
//   * a 45-degree cut plane x + z <= 52 (a diagonal edge),
//   * a 15.000 mm bore (R 7.500) through the thickness at (16, 16), declared
//     as a PROTECTED FEATURE via resolve_clearance_manual — the existing
//     clearance machinery, zero concentric margin so the declared radius IS
//     the bore radius.
//
// Modes:
//   evidence <outdir> <cell_mm> <uniform|graded>   the boundary finish
//   before   <outdir> <cell_mm>                    the old defective behaviour
// Each run prints KEY=value lines (the table rows) and writes the STL.
// One cell size per process so ru_maxrss is per-configuration (bar B8).

#include "topopt/clearance.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"

#include <sys/resource.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

// ── the evidence part ────────────────────────────────────────────────────────
static constexpr double kBoxX = 48.0, kBoxY = 32.0, kBoxZ = 16.0;
static constexpr double kBoreR = 7.5;  // 15.000 mm bore
static constexpr double kBoreCx = 16.0, kBoreCy = 16.0;

static ClearanceGeometry evidence_bore() {
  ManualClearanceGeometry mg;
  mg.kind = ClearanceKind::Bolt;
  mg.axis_point = {kBoreCx, kBoreCy, kBoxZ * 0.5};
  mg.axis_dir = {0, 0, 1};
  mg.radius_mm = kBoreR;
  mg.half_length_mm = kBoxZ * 0.5 + 4.0;  // through-part + driver access
  ClearanceParams p;  // zero concentric margin: declared radius == bore radius
  p.kind = ClearanceKind::Bolt;
  p.concentric_margin_mm = 0.0;
  p.axial_clearance_mm = 0.0;
  return resolve_clearance_manual(mg, p);
}

static LatticeBoundary evidence_boundary() {
  LatticeBoundary B;
  B.add_box({0, 0, 0}, {kBoxX, kBoxY, kBoxZ});
  // Diagonal edge: 45-degree cut x + z <= 52 (plane through (44, y, 8)).
  B.add_half_space({44.0, kBoxY * 0.5, 8.0},
                   {1.0 / std::sqrt(2.0), 0.0, 1.0 / std::sqrt(2.0)});
  B.add_keep_out(evidence_bore(), /*collar=*/true);
  return B;
}

static LatticeRegion evidence_region(double cell, const LatticeBoundary* B) {
  LatticeRegion R;
  R.origin = {0, 0, 0};
  R.nx = static_cast<int>(std::ceil(kBoxX / cell));
  R.ny = static_cast<int>(std::ceil(kBoxY / cell));
  R.nz = static_cast<int>(std::ceil(kBoxZ / cell));
  R.cell_mm = cell;
  R.boundary = B;
  return R;
}

// The graded field (bar B5's trap: overshoot WITH GRADING ON): radius rises
// linearly across the height, 0.5 -> 1.0 mm.
static LatticeRadiusField field_for(bool graded, double uniform_r) {
  LatticeRadiusField G;
  G.nseg = 8;
  if (graded)
    G.field = [](Vec3 p) {
      const double t = std::min(1.0, std::max(0.0, p.z / kBoxZ));
      return 0.5 + 0.5 * t;
    };
  else
    G.uniform_mm = uniform_r;
  return G;
}

// ── measurements ─────────────────────────────────────────────────────────────
struct SegElem {  // a skin/collar/rim solid reduced to segment + radius
  Vec3 a, b;
  double r;
  LatticeGenElement kind;
};

static double point_seg_dist(const Vec3& p, const Vec3& a, const Vec3& b) {
  const double ax = b.x - a.x, ay = b.y - a.y, az = b.z - a.z;
  const double l2 = ax * ax + ay * ay + az * az;
  double t = 0.0;
  if (l2 > 0.0)
    t = std::max(0.0, std::min(1.0, ((p.x - a.x) * ax + (p.y - a.y) * ay +
                                     (p.z - a.z) * az) /
                                        l2));
  const double dx = p.x - (a.x + t * ax), dy = p.y - (a.y + t * ay),
               dz = p.z - (a.z + t * az);
  return std::sqrt(dx * dx + dy * dy + dz * dz);
}

// B4: project all triangles along axis `ax` (0/1/2) onto a 0.25mm raster of
// the part silhouette; report see-through (silhouette columns with no
// geometry): total area and largest 4-connected patch.
static void see_through(const TriangleMesh& m, const LatticeBoundary& B, int ax,
                        double& total_mm2, double& largest_mm2) {
  const double cellsz = 0.25;
  const double ext[3] = {kBoxX, kBoxY, kBoxZ};
  const int u_ax = (ax + 1) % 3, v_ax = (ax + 2) % 3;
  const int nu = static_cast<int>(std::ceil(ext[u_ax] / cellsz));
  const int nv = static_cast<int>(std::ceil(ext[v_ax] / cellsz));
  auto comp = [](const Vec3& p, int a) { return a == 0 ? p.x : a == 1 ? p.y : p.z; };

  // Silhouette: a column is material iff any depth sample is inside the
  // allowed region (keep-outs subtracted, so the bore column is a HOLE by
  // design, not see-through).
  std::vector<char> sil(static_cast<std::size_t>(nu) * nv, 0);
  const int nd = static_cast<int>(std::ceil(ext[ax] / cellsz));
  for (int iu = 0; iu < nu; ++iu)
    for (int iv = 0; iv < nv; ++iv) {
      const double u = (iu + 0.5) * cellsz, v = (iv + 0.5) * cellsz;
      for (int id = 0; id <= nd; ++id) {
        const double d = std::min(ext[ax] - 1e-6, (id + 0.5) * cellsz);
        double c[3];
        c[ax] = d;
        c[u_ax] = u;
        c[v_ax] = v;
        if (B.signed_distance({c[0], c[1], c[2]}) > 0.0) {
          sil[static_cast<std::size_t>(iu) * nv + iv] = 1;
          break;
        }
      }
    }

  // Coverage: raster cells whose centre falls in a projected triangle.
  std::vector<char> cov(static_cast<std::size_t>(nu) * nv, 0);
  for (const auto& t : m.triangles) {
    const Vec3& A = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& Bv = m.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& C = m.vertices[static_cast<std::size_t>(t[2])];
    const double au = comp(A, u_ax), av = comp(A, v_ax);
    const double bu = comp(Bv, u_ax), bv = comp(Bv, v_ax);
    const double cu = comp(C, u_ax), cv = comp(C, v_ax);
    const int iu0 = std::max(0, static_cast<int>(std::floor(
                                    std::min({au, bu, cu}) / cellsz)));
    const int iu1 = std::min(nu - 1, static_cast<int>(std::ceil(
                                         std::max({au, bu, cu}) / cellsz)));
    const int iv0 = std::max(0, static_cast<int>(std::floor(
                                    std::min({av, bv, cv}) / cellsz)));
    const int iv1 = std::min(nv - 1, static_cast<int>(std::ceil(
                                         std::max({av, bv, cv}) / cellsz)));
    const double d00 = bu - au, d01 = bv - av, d10 = cu - au, d11 = cv - av;
    const double det = d00 * d11 - d10 * d01;
    if (std::fabs(det) < 1e-15) continue;  // edge-on triangle: no area
    for (int iu = iu0; iu <= iu1; ++iu)
      for (int iv = iv0; iv <= iv1; ++iv) {
        const double pu = (iu + 0.5) * cellsz - au;
        const double pv = (iv + 0.5) * cellsz - av;
        const double l1 = (pu * d11 - pv * d10) / det;
        const double l2 = (pv * d00 - pu * d01) / det;
        if (l1 >= -1e-9 && l2 >= -1e-9 && l1 + l2 <= 1.0 + 1e-9)
          cov[static_cast<std::size_t>(iu) * nv + iv] = 1;
      }
  }

  // See-through components (4-connected flood fill over sil && !cov).
  std::vector<int> label(static_cast<std::size_t>(nu) * nv, -1);
  total_mm2 = largest_mm2 = 0.0;
  std::vector<std::size_t> stack;
  for (int iu = 0; iu < nu; ++iu)
    for (int iv = 0; iv < nv; ++iv) {
      const std::size_t e = static_cast<std::size_t>(iu) * nv + iv;
      if (!sil[e] || cov[e] || label[e] >= 0) continue;
      long long cells = 0;
      stack.assign(1, e);
      label[e] = 1;
      while (!stack.empty()) {
        const std::size_t cur = stack.back();
        stack.pop_back();
        ++cells;
        const int cu2 = static_cast<int>(cur / nv), cv2 = static_cast<int>(cur % nv);
        const int du[4] = {1, -1, 0, 0}, dv[4] = {0, 0, 1, -1};
        for (int q = 0; q < 4; ++q) {
          const int nu2 = cu2 + du[q], nv2 = cv2 + dv[q];
          if (nu2 < 0 || nv2 < 0 || nu2 >= nu || nv2 >= nv) continue;
          const std::size_t ne = static_cast<std::size_t>(nu2) * nv + nv2;
          if (!sil[ne] || cov[ne] || label[ne] >= 0) continue;
          label[ne] = 1;
          stack.push_back(ne);
        }
      }
      const double area = cells * cellsz * cellsz;
      total_mm2 += area;
      largest_mm2 = std::max(largest_mm2, area);
    }
}

int main(int argc, char** argv) {
  if (argc < 4) {
    std::fprintf(stderr,
                 "usage: %s evidence <outdir> <cell_mm> <uniform|graded>\n"
                 "       %s before   <outdir> <cell_mm>\n",
                 argv[0], argv[0]);
    return 2;
  }
  const std::string mode = argv[1];
  const std::string outdir = argv[2];
  const double cell = std::atof(argv[3]);
  const bool graded = (argc > 4 && std::strcmp(argv[4], "graded") == 0);
  const bool before = (mode == "before");
  const double uniform_r = 0.8;

  const LatticeBoundary B = evidence_boundary();
  LatticeRegion R = evidence_region(cell, before ? nullptr : &B);
  if (before) {
    // The OLD rule, reproduced: a cell is latticed iff its CENTRE is in the
    // allowed region (part minus keep-out — run_job's FrozenVoid-carrying
    // density), and its struts are emitted WHOLE. No clip, no skin.
    const LatticeBoundary* Bp = &B;
    const double c = cell;
    R.latticed = [Bp, c](int ci, int cj, int ck) {
      const Vec3 p{(ci + 0.5) * c, (cj + 0.5) * c, (ck + 0.5) * c};
      return Bp->signed_distance(p) > 0.0;
    };
  }
  const LatticeRadiusField G = field_for(graded, uniform_r);
  LatticeSkinSpec S;
  if (!before) {
    S.mode = LatticeSkinMode::Diagrid;
    // The skin's printability clamp, read from CORE's law for a stated
    // 0.8 mm extrudable width (never hardcoded here).
    S.min_radius_mm = lattice_skin_min_radius_mm(0.8);
  }

  // Observed landings + skin/collar elements for the B6 measurement.
  struct L {
    Vec3 pos;
    double r;
  };
  std::vector<L> landings;
  std::vector<SegElem> skin_elems;
  LatticeGenObserver obs;
  obs.on_landing = [&](const Vec3& p, double r, int) {
    landings.push_back({p, r});
  };
  obs.on_element = [&](LatticeGenElement k, const Vec3& a, const Vec3& b,
                       double r) {
    if (k == LatticeGenElement::SkinStrut || k == LatticeGenElement::RimStrut ||
        k == LatticeGenElement::RimTorusChord ||
        k == LatticeGenElement::AnchorNode)
      skin_elems.push_back({a, b, r, k});
  };

  const std::string name = mode + (graded ? "_graded" : "") + "_" +
                           std::to_string(static_cast<int>(cell)) + "mm";
  const std::string stl_path = outdir + "/" + name + ".stl";

  // (1) STREAMED write, NO observer — the B8 RSS measurement path. ru_maxrss is
  // snapshotted immediately after, before any measurement-side accumulation
  // (the observer vectors and the in-memory mesh below are PROBE memory, not
  // the generator's; recording them would misattribute the growth).
  const auto t0 = std::chrono::steady_clock::now();
  LatticeGenStats st;
  {
    StreamingStlWriter w(stl_path);
    st = generate_lattice(LatticeGenTopology::Octet, R, G, w, S, nullptr);
    w.finish();
  }
  const double gen_s =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
          .count();
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);

  // (2) In-memory copy of the SAME geometry, WITH the observer, for the vertex
  // and B6 measurements (test_lattice_gen proves streamed == buffered).
  MeshSink ms;
  generate_lattice(LatticeGenTopology::Octet, R, G, ms, S, &obs);
  const TriangleMesh& m = ms.mesh;

  // ── B2: protected-feature intrusion, measured over EVERY EMITTED VERTEX ──
  long long b2_inside = 0;
  double b2_min_r = 1e30;
  for (const auto& v : m.vertices) {
    if (v.z < -4.0 || v.z > kBoxZ + 4.0) continue;  // the declared axial band
    const double rad = std::hypot(v.x - kBoreCx, v.y - kBoreCy);
    if (rad < kBoreR + 4.0) b2_min_r = std::min(b2_min_r, rad);
    if (rad < kBoreR - 1e-9) ++b2_inside;
  }

  // ── B5: overshoot past the true silhouette (per-vertex, exact SDF) ────────
  double b5_max_overshoot = 0.0;
  for (const auto& v : m.vertices)
    b5_max_overshoot = std::max(b5_max_overshoot, -B.signed_distance(v));

  // ── B4: see-through projections along the three axes ─────────────────────
  double st_tot[3], st_big[3];
  for (int ax = 0; ax < 3; ++ax) see_through(m, B, ax, st_tot[ax], st_big[ax]);

  // ── B6: floating cut ends (landings vs the skin/collar network) ──────────
  // "anchored" counts the anchor ball placed AT the landing (by construction);
  // "connected" is the stricter test — the cut end must touch skin/rim/collar
  // material BEYOND its own anchor: another element's solid within reach.
  long long floating_strict = 0;
  for (const auto& L2 : landings) {
    bool touch = false;
    for (const auto& e : skin_elems) {
      if (e.kind == LatticeGenElement::AnchorNode &&
          point_seg_dist(L2.pos, e.a, e.b) < 1e-9)
        continue;  // its own anchor
      if (point_seg_dist(L2.pos, e.a, e.b) <= L2.r + e.r + 1e-6) {
        touch = true;
        break;
      }
    }
    if (!touch) ++floating_strict;
  }

  // ── B10: determinism (regenerate, byte-compare) ───────────────────────────
  const std::string stl2 = outdir + "/" + name + "_rerun.stl";
  {
    StreamingStlWriter w(stl2);
    LatticeGenObserver o3;
    generate_lattice(LatticeGenTopology::Octet, R, G, w, S, &o3);
    w.finish();
  }
  bool identical = false;
  {
    std::ifstream fa(stl_path, std::ios::binary), fb(stl2, std::ios::binary);
    std::string sa((std::istreambuf_iterator<char>(fa)), {});
    std::string sb((std::istreambuf_iterator<char>(fb)), {});
    identical = !sa.empty() && sa == sb;
  }
  std::remove(stl2.c_str());

  // ── report ────────────────────────────────────────────────────────────────
  std::printf("MODE=%s CELL=%g GRADED=%d\n", mode.c_str(), cell, graded ? 1 : 0);
  std::printf("STL=%s\n", stl_path.c_str());
  std::printf("TRIANGLES=%llu STRUTS=%llu NODES=%llu CELLS=%lld\n",
              (unsigned long long)st.triangles, (unsigned long long)st.struts,
              (unsigned long long)st.nodes, st.latticed_cells);
  std::printf("CLIPPED=%llu DROPPED=%llu FRAGMENTS=%llu LANDINGS=%llu "
              "ANCHORS=%llu SKIN_STRUTS=%llu RIM_ELEMENTS=%llu UNCERT=%lld "
              "SKEW_RIMS=%lld\n",
              (unsigned long long)st.clipped_struts,
              (unsigned long long)st.dropped_struts,
              (unsigned long long)st.strut_fragments,
              (unsigned long long)st.landings,
              (unsigned long long)st.anchor_nodes,
              (unsigned long long)st.skin_struts,
              (unsigned long long)st.rim_elements,
              st.uncertified_spans_dropped, st.skipped_nonorthogonal_rims);
  std::printf("SKIN_TRIS=%llu RIM_TRIS=%llu\n",
              (unsigned long long)st.skin_triangles,
              (unsigned long long)st.rim_triangles);
  std::printf("B2_INSIDE_VERTICES=%lld B2_MIN_RADIUS=%.3f (declared %.3f)\n",
              b2_inside, b2_min_r, kBoreR);
  std::printf("B5_MAX_OVERSHOOT_MM=%.6f\n", b5_max_overshoot);
  std::printf("B4_X_TOTAL=%.2f B4_X_LARGEST=%.2f\n", st_tot[0], st_big[0]);
  std::printf("B4_Y_TOTAL=%.2f B4_Y_LARGEST=%.2f\n", st_tot[1], st_big[1]);
  std::printf("B4_Z_TOTAL=%.2f B4_Z_LARGEST=%.2f\n", st_tot[2], st_big[2]);
  std::printf("B6_LANDINGS=%zu B6_FLOATING_STRICT=%lld\n", landings.size(),
              floating_strict);
  std::printf("B9_INTERIOR_MM3=%.1f B9_SKIN_MM3=%.1f B9_RIM_MM3=%.1f\n",
              st.interior_volume_mm3, st.skin_volume_mm3, st.rim_volume_mm3);
  std::printf("B10_BYTE_IDENTICAL=%d\n", identical ? 1 : 0);
  std::printf("B8_PEAK_RSS_BYTES=%ld GEN_SECONDS=%.3f\n", ru.ru_maxrss, gen_s);
  return 0;
}
