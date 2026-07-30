// Unit tests for the lattice boundary finish (handoff
// 2026-07-29-lattice-boundary-finish): the shared boundary predicate
// (LatticeBoundary), solid-safe clipping, overlap activation, the anchored
// skin, and the generator/certification-mask agreement (bar B7).
//
// The B3 test is ADVERSARIAL BY CONSTRUCTION: it also runs the naive
// centreline-clipped variant (the same clip with the boundary pre-offset
// outward by the strut radius, which is exactly what clipping the LINE at the
// true surface produces) and REQUIRES it to protrude — proving this test fails
// against a centreline-clipped implementation.
//
// Self-contained CHECK harness (ARCHITECTURE §4 locks the dependency set).
// LATTICE_TMP_DIR (a writable throwaway dir) is injected by CMake.

#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

static std::string tmp(const std::string& name) {
  return std::string(LATTICE_TMP_DIR) + "/" + name;
}

static bool files_identical(const std::string& a, const std::string& b) {
  std::ifstream fa(a, std::ios::binary), fb(b, std::ios::binary);
  if (!fa || !fb) return false;
  std::string sa((std::istreambuf_iterator<char>(fa)), {});
  std::string sb((std::istreambuf_iterator<char>(fb)), {});
  return sa == sb;
}

// A bore keep-out through a plate: the resolved ClearanceGeometry the existing
// clearance machinery produces (resolve_clearance_manual with zero margins
// yields exactly this shape; built directly here to keep the test headless).
static ClearanceGeometry bore(Vec3 base, Vec3 axis, double radius, double t_lo,
                              double t_hi) {
  ClearanceGeometry g;
  g.kind = ClearanceKind::Bolt;
  g.valid = true;
  g.axis_point = base;
  const double n = std::sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z);
  g.axis_dir = {axis.x / n, axis.y / n, axis.z / n};
  g.radius = radius;
  g.t_lo = t_lo;
  g.t_hi = t_hi;
  return g;
}

int main() {
  // ---- 1. SDF exactness on the primitives ------------------------------------
  {
    LatticeBoundary B;
    B.add_box({0, 0, 0}, {40, 30, 20});
    B.add_keep_out(bore({20, 15, -5}, {0, 0, 1}, 6.0, -5.0, 30.0), true);

    CHECK(std::fabs(B.signed_distance({1.0, 15, 10}) - 1.0) < 1e-12,
          "sd 1mm inside the x=0 wall is exactly 1");
    CHECK(std::fabs(B.signed_distance({-3.0, 15, 10}) + 3.0) < 1e-12,
          "sd 3mm outside the x=0 wall is exactly -3");
    // 8mm from the bore axis = 2mm outside the 6mm keep-out wall (and >2mm from
    // every box wall): the keep-out term governs and is exact.
    CHECK(std::fabs(B.signed_distance({28, 15, 10}) - 2.0) < 1e-12,
          "sd 2mm outside the bore wall is exactly 2");
    CHECK(std::fabs(B.signed_distance({22, 15, 10}) + 4.0) < 1e-12,
          "sd 4mm inside the keep-out is exactly -4");
    CHECK(B.in_keep_out({20, 15, 10}, 0.0), "bore centre is in the keep-out");
    CHECK(!B.in_keep_out({28, 15, 10}, 0.0), "outside the wall is not");
    CHECK(B.faces().size() == 7, "6 box faces + 1 bore face");
  }

  // ---- 2. clip_segment: certified spans, exact crossings ----------------------
  {
    LatticeBoundary B;
    B.add_half_space({0, 0, 10}, {0, 0, 1});  // material below z=10
    // Vertical segment crossing the eroded surface z = 10 - r at r = 0.8.
    auto spans = B.clip_segment({0, 0, 0}, {0, 0, 20}, 0.8, -1, -1, nullptr);
    CHECK(spans.size() == 1, "one kept span below the plane");
    CHECK(spans[0].t0 == 0.0, "kept span starts at the segment start");
    CHECK(std::fabs(spans[0].t1 - 9.2) < 2e-4,
          "kept span ends at z = 10 - 0.8 to the clip tolerance");
    // A segment entirely outside keeps nothing; entirely (deep) inside keeps all.
    CHECK(B.clip_segment({0, 0, 11}, {5, 0, 12}, 0.5, -1, -1, nullptr).empty(),
          "outside segment keeps nothing");
    auto all = B.clip_segment({0, 0, 1}, {5, 0, 1}, 0.5, -1, -1, nullptr);
    CHECK(all.size() == 1 && all[0].t0 == 0.0 && std::fabs(all[0].t1 - 5.0) < 1e-12,
          "deep-inside segment keeps everything");
    // Re-entry: a segment passing THROUGH a keep-out splits in two.
    LatticeBoundary B2;
    B2.add_box({0, 0, 0}, {40, 10, 10});
    B2.add_keep_out(bore({20, 5, -1}, {0, 0, 1}, 4.0, -1.0, 12.0), true);
    auto two = B2.clip_segment({2, 5, 5}, {38, 5, 5}, 1.0, -1, -1, nullptr);
    CHECK(two.size() == 2, "segment through a bore splits into two spans");
    if (two.size() == 2) {
      CHECK(std::fabs((2.0 + two[0].t1) - (20.0 - 5.0)) < 2e-4,
            "first span ends at 5mm (bore R + erosion) before the axis");
      CHECK(std::fabs((2.0 + two[1].t0) - (20.0 + 5.0)) < 2e-4,
            "second span resumes 5mm past the axis");
    }
  }

  // ---- 3. B3 — CLIP THE SOLID, NOT THE LINE (adversarial vs naive) ------------
  // A diagonal cut plane so octet struts meet it OBLIQUELY. The REAL clip must
  // leave zero vertex overshoot; the NAIVE variant (same machinery, boundary
  // offset out by r == centreline clipping at the true surface) MUST protrude,
  // proving this check fails against a centreline-clipped implementation.
  {
    const double r = 0.8;
    const Vec3 n_cut{1.0 / std::sqrt(2.0), 0.0, 1.0 / std::sqrt(2.0)};
    const Vec3 o_cut{28.0, 0.0, 0.0};  // diagonal plane x+z = 28 (in-plane point)

    auto run = [&](double plane_shift, double& max_over) {
      LatticeBoundary B;
      B.add_box({0, 0, 0}, {40, 24, 24});
      // Shift the cut plane OUTWARD along its normal by plane_shift: 0 = the
      // real boundary; +r = erosion-r clipping degenerates to clipping the
      // CENTRELINE at the true surface (the naive implementation).
      B.add_half_space({o_cut.x + n_cut.x * plane_shift, o_cut.y,
                        o_cut.z + n_cut.z * plane_shift},
                       n_cut);
      LatticeRegion R;
      R.nx = R.ny = R.nz = 5;
      R.cell_mm = 8.0;
      R.boundary = &B;
      LatticeRadiusField G;
      G.uniform_mm = r;
      MeshSink ms;
      generate_lattice(LatticeGenTopology::Octet, R, G, ms);
      max_over = -1e30;
      for (const auto& v : ms.mesh.vertices) {
        const double d = (v.x - o_cut.x) * n_cut.x + (v.z - o_cut.z) * n_cut.z;
        max_over = std::max(max_over, d);  // >0 = past the TRUE cut plane
      }
      return ms.mesh.vertices.size();
    };

    double over_real = 0.0, over_naive = 0.0;
    const std::size_t nv_real = run(0.0, over_real);
    run(r, over_naive);
    std::printf("B3 oblique: real overshoot=%.6f mm, naive(centreline)=%.6f mm "
                "(%zu vertices)\n",
                over_real, over_naive, nv_real);
    CHECK(nv_real > 0, "oblique fixture emits geometry");
    CHECK(over_real <= 1e-9, "B3: no vertex passes the true cut plane");
    CHECK(over_naive > 0.3 * r,
          "B3 adversarial: the naive centreline clip PROTRUDES (the test would "
          "fail against it)");
  }

  // ---- 4. Overlap activation fills cells the centre rule dropped -------------
  {
    // Region block deliberately offset so boundary cells have centres OUTSIDE
    // the part but overlap it: the centre rule drops them whole (see-through),
    // overlap activation emits their partial struts.
    LatticeBoundary B;
    B.add_box({0, 0, 0}, {20, 20, 5.5});  // thin plate: top cells overlap 1.5mm
    LatticeRegion R;
    R.nx = R.ny = 5;
    R.nz = 2;
    R.cell_mm = 4.0;
    R.boundary = &B;
    LatticeRadiusField G;
    G.uniform_mm = 0.4;
    MeshSink ms;
    LatticeGenStats st = generate_lattice(LatticeGenTopology::Octet, R, G, ms);
    CHECK(st.latticed_cells == 50, "overlap activation keeps the partial top layer");
    CHECK(st.clipped_struts > 0, "partial cells were clipped, not dropped whole");
    double max_z = -1e30;
    for (const auto& v : ms.mesh.vertices) max_z = std::max(max_z, v.z);
    CHECK(max_z > 4.0 + 0.1, "geometry actually reaches into the partial layer");
    CHECK(max_z <= 5.5 + 1e-9, "clipped geometry never leaves the part");
  }

  // ---- 5. B7 — generator and certification mask share the ONE predicate -------
  {
    // A voxel-solid blob (the run_job base) + an analytic bore keep-out.
    VoxelGrid grid;
    grid.nx = grid.ny = 24;
    grid.nz = 12;
    grid.spacing = 1.0;
    grid.origin = {0, 0, 0};
    grid.tags.assign(static_cast<std::size_t>(grid.nx) * grid.ny * grid.nz,
                     VoxelTag::Empty);
    std::vector<double> dens(grid.voxel_count(), 0.0);
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          // a solid slab with a corner notch (irregular silhouette)
          const bool solid = !(i > 15 && j > 15);
          dens[grid.index(i, j, k)] = solid ? 1.0 : 0.0;
        }
    LatticeBoundary B;
    B.set_voxel_base(&grid, &dens, 0.5, 2.0 * 4.0);
    B.add_keep_out(bore({8, 8, -2}, {0, 0, 1}, 3.0, -2.0, 16.0), true);

    LatticeRegion R;
    R.nx = R.ny = 6;
    R.nz = 3;
    R.cell_mm = 4.0;
    R.boundary = &B;
    LatticeRadiusField G;
    G.uniform_mm = 0.5;
    MeshSink ms;
    LatticeGenStats st = generate_lattice(LatticeGenTopology::Octet, R, G, ms);
    CHECK(st.triangles > 0, "voxel-base fixture emits geometry");

    const std::vector<char> mask =
        lattice_certification_mask(B, grid, dens, 0.5, R.origin, R.cell_mm);
    // Every emitted vertex must land in (or on the boundary of) a voxel the
    // mask marks latticed — the generator's silhouette and the certification
    // mask agree because they are the SAME predicate.
    std::size_t off_mask = 0;
    for (const auto& v : ms.mesh.vertices) {
      const int i = static_cast<int>(std::floor(v.x / grid.spacing));
      const int j = static_cast<int>(std::floor(v.y / grid.spacing));
      const int k = static_cast<int>(std::floor(v.z / grid.spacing));
      bool near_masked = false;
      for (int dk = -1; dk <= 1 && !near_masked; ++dk)
        for (int dj = -1; dj <= 1 && !near_masked; ++dj)
          for (int di = -1; di <= 1 && !near_masked; ++di) {
            const int ii = i + di, jj = j + dj, kk = k + dk;
            if (ii < 0 || jj < 0 || kk < 0 || ii >= grid.nx || jj >= grid.ny ||
                kk >= grid.nz)
              continue;
            if (mask[grid.index(ii, jj, kk)]) near_masked = true;
          }
      if (!near_masked) ++off_mask;
    }
    std::printf("B7 agreement: %zu vertices, %zu outside the mask "
                "neighbourhood\n", ms.mesh.vertices.size(), off_mask);
    CHECK(off_mask == 0, "B7: every emitted vertex lies in the certified region");
    // And the mask honours the keep-out: no masked voxel centre inside it.
    std::size_t masked_in_keepout = 0;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          if (!mask[grid.index(i, j, k)]) continue;
          const Vec3 c{(i + 0.5) * grid.spacing, (j + 0.5) * grid.spacing,
                       (k + 0.5) * grid.spacing};
          if (B.in_keep_out(c, 0.0)) ++masked_in_keepout;
        }
    CHECK(masked_in_keepout == 0, "mask excludes keep-out voxels");
  }

  // ---- 6. Skin: anchors at landings, edges + rims emitted, all inside --------
  {
    LatticeBoundary B;
    B.add_box({0, 0, 0}, {32, 32, 16});
    B.add_keep_out(bore({16, 16, -4}, {0, 0, 1}, 5.0, -4.0, 24.0), true);
    LatticeRegion R;
    R.nx = R.ny = 4;
    R.nz = 2;
    R.cell_mm = 8.0;
    R.boundary = &B;
    LatticeRadiusField G;
    G.uniform_mm = 0.8;
    LatticeSkinSpec S;
    S.mode = LatticeSkinMode::Diagrid;
    S.min_radius_mm = lattice_skin_min_radius_mm(2.0 * 0.8);  // clamp from core
    MeshSink ms;
    LatticeGenStats st = generate_lattice(LatticeGenTopology::Octet, R, G, ms, S);
    std::printf("skin: landings=%llu anchors=%llu skin_struts=%llu rims=%llu "
                "skin_tris=%llu rim_tris=%llu\n",
                (unsigned long long)st.landings, (unsigned long long)st.anchor_nodes,
                (unsigned long long)st.skin_struts,
                (unsigned long long)st.rim_elements,
                (unsigned long long)st.skin_triangles,
                (unsigned long long)st.rim_triangles);
    CHECK(st.landings > 0, "boundary cells produce landings");
    CHECK(st.anchor_nodes == st.landings, "one anchor ball per landing (B6)");
    CHECK(st.skin_struts > 0, "diagrid edges emitted");
    CHECK(st.rim_elements > 0, "rim loops emitted (box edges + bore tori)");
    CHECK(st.skin_volume_mm3 > 0.0 && st.rim_volume_mm3 > 0.0,
          "B9: skin and rim volumes accounted");
    // B2 on the bore: no vertex strictly inside the declared keep-out, and the
    // collar's rim tori TOUCH the wall: min radius == declared to 3 decimals.
    double min_rad = 1e30;
    std::size_t inside = 0;
    for (const auto& v : ms.mesh.vertices) {
      const double rad = std::hypot(v.x - 16.0, v.y - 16.0);
      if (v.z >= 0.0 && v.z <= 16.0) {
        min_rad = std::min(min_rad, rad);
        if (rad < 5.0 - 1e-9) ++inside;
      }
    }
    std::printf("skin B2: min radius=%.6f (declared 5.000), inside=%zu\n",
                min_rad, inside);
    CHECK(inside == 0, "B2: zero vertices inside the protected bore");
    CHECK(std::fabs(min_rad - 5.0) < 5e-4,
          "B2: collar touches the declared radius to 3 decimals");
    // Rim-only mode emits rims but no diagrid.
    LatticeSkinSpec rim_only;
    rim_only.mode = LatticeSkinMode::Rim;
    rim_only.min_radius_mm = S.min_radius_mm;
    MeshSink mr;
    LatticeGenStats sr = generate_lattice(LatticeGenTopology::Octet, R, G, mr,
                                          rim_only);
    CHECK(sr.rim_elements > 0 && sr.skin_struts == 0 && sr.anchor_nodes == 0,
          "rim-only mode emits just the edge loops");
  }

  // ---- 7. B10 determinism with boundary + skin --------------------------------
  {
    LatticeBoundary B;
    B.add_box({0, 0, 0}, {32, 24, 16});
    B.add_half_space({24, 12, 8}, {1, 0, 1});  // oblique cut
    B.add_keep_out(bore({10, 12, -4}, {0, 0, 1}, 4.0, -4.0, 24.0), true);
    LatticeRegion R;
    R.nx = 4;
    R.ny = 3;
    R.nz = 2;
    R.cell_mm = 8.0;
    R.boundary = &B;
    LatticeRadiusField G;
    G.field = [](Vec3 p) { return 0.6 + 0.02 * p.z; };  // graded, for good measure
    LatticeSkinSpec S;
    S.mode = LatticeSkinMode::Diagrid;
    S.min_radius_mm = lattice_skin_min_radius_mm(1.2);
    const std::string a = tmp("bound_det_a.stl"), b = tmp("bound_det_b.stl");
    {
      StreamingStlWriter w(a);
      generate_lattice(LatticeGenTopology::Octet, R, G, w, S);
      w.finish();
    }
    {
      StreamingStlWriter w(b);
      generate_lattice(LatticeGenTopology::Octet, R, G, w, S);
      w.finish();
    }
    CHECK(files_identical(a, b),
          "B10: boundary + skin runs are byte-identical across runs");
  }

  // ---- 8. LATTICE ROLES (task lattice-page-core-hookup, H1a/H1b) --------------
  // include / exclude regions on the SAME shared predicate: precedence is
  // explicit and tested for EVERY pair, and the generator's cell activation and
  // the certification mask stay coherent (a masked voxel's owning cell is
  // always active; a cell provably inside an exclude region never emits).
  {
    // An all-solid voxel slab 24 x 24 x 12 (spacing 1mm).
    VoxelGrid grid;
    grid.nx = grid.ny = 24;
    grid.nz = 12;
    grid.spacing = 1.0;
    grid.origin = {0, 0, 0};
    grid.tags.assign(static_cast<std::size_t>(grid.nx) * grid.ny * grid.nz,
                     VoxelTag::Empty);
    std::vector<double> dens(grid.voxel_count(), 1.0);
    // ...except a void pocket at the far corner (include-over-void case).
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 20; j < 24; ++j)
        for (int i = 0; i < 4; ++i) dens[grid.index(i, j, k)] = 0.0;

    // An INCLUDE slab covering x in [0, 12] (full y/z extent): a bounded-slab
    // ClearanceGeometry exactly as resolve_clearance_manual produces.
    ClearanceGeometry incl;
    incl.kind = ClearanceKind::Face;
    incl.valid = true;
    incl.origin = {0, 12, 6};
    incl.normal = {1, 0, 0};
    incl.u = {0, 1, 0};
    incl.w = {0, 0, 1};
    incl.u_lo = -50;
    incl.u_hi = 50;
    incl.w_lo = -50;
    incl.w_hi = 50;
    incl.depth = 12;
    // An EXCLUDE bolt column inside the include region at (6, 6).
    const ClearanceGeometry excl = bore({6, 6, -2}, {0, 0, 1}, 3.0, -2.0, 16.0);
    // A CLEARANCE keep-out inside the include region at (6, 18).
    const ClearanceGeometry ko = bore({6, 18, -2}, {0, 0, 1}, 3.0, -2.0, 16.0);

    LatticeBoundary B;
    B.set_voxel_base(&grid, &dens, 0.5, 2.0 * 4.0);
    B.add_keep_out(ko, true);
    B.add_include_region(incl);
    B.add_exclude_region(excl);

    // Membership predicates (the SAME point_in_clearance_region math as the
    // keep-out / rasterizer membership).
    CHECK(B.has_include_regions(), "roles: include region registered");
    CHECK(B.in_include_region({3, 12, 6}, 0.0), "roles: point inside include");
    CHECK(!B.in_include_region({18, 12, 6}, 0.0), "roles: point outside include");
    CHECK(B.in_exclude_region({6, 6, 6}, 0.0), "roles: point inside exclude");
    CHECK(!B.in_exclude_region({6, 18, 6}, 0.0),
          "roles: clearance bore is NOT an exclude region (distinct stores)");

    const double cell = 4.0;
    const std::vector<char> mask =
        lattice_certification_mask(B, grid, dens, 0.5, grid.origin, cell);
    auto m = [&](int i, int j, int k) { return mask[grid.index(i, j, k)] != 0; };

    // PRECEDENCE — every pair (H1a):
    // include alone => latticed.
    CHECK(m(3, 12, 6), "H1a: voxel in include (only) is latticed");
    // outside the include union (no other role) => solid.
    CHECK(!m(18, 12, 6), "H1a: voxel outside the include union stays solid");
    // include ∧ exclude => exclude wins (solid).
    CHECK(!m(6, 6, 6), "H1a: exclude beats include — overlap stays solid");
    // include ∧ clearance => clearance wins (nothing to lattice).
    CHECK(!m(6, 18, 6), "H1a: clearance beats include");
    // include over optimizer VOID => no-op (no material, nothing marked).
    CHECK(!m(2, 22, 6), "H1a: include over void marks nothing (no-op)");
    // exclude ∧ clearance: still solid/nothing — and the clearance keeps its
    // today's semantics (struts are CLIPPED there; the exclude alone does not
    // clip). Prove via the sd: the keep-out subtracts from the allowed region,
    // the exclude does not.
    CHECK(B.signed_distance({6, 18, 6}) < 0.0,
          "clearance subtracts from the allowed (clip) region");
    CHECK(B.signed_distance({6, 6, 6}) > 0.0,
          "exclude does NOT subtract from the clip region (solid material — "
          "struts weld into it, they are not clipped short of it)");

    // Coherence (H1b): every masked voxel's owning cell is generator-ACTIVE.
    std::size_t masked = 0, masked_cell_inactive = 0;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          if (!m(i, j, k)) continue;
          ++masked;
          const Vec3 c{(i + 0.5), (j + 0.5), (k + 0.5)};
          const Vec3 cell_min{std::floor(c.x / cell) * cell,
                              std::floor(c.y / cell) * cell,
                              std::floor(c.z / cell) * cell};
          if (!B.cell_may_overlap(cell_min, cell)) ++masked_cell_inactive;
        }
    CHECK(masked > 0, "roles fixture: some voxels are latticed");
    CHECK(masked_cell_inactive == 0,
          "H1b: every masked voxel's owning cell is active — silhouette and "
          "mask cannot disagree");
    // A cell provably inside the exclude column is INACTIVE (emits nothing)...
    CHECK(!B.cell_may_overlap({5.5, 5.5, 5.5}, 1.0),
          "a cell provably inside an exclude region is inactive");
    // ...and a cell provably outside every include region is INACTIVE too.
    CHECK(!B.cell_may_overlap({18, 18, 4}, 2.0),
          "a cell provably outside the include union is inactive");
    // Fewer active cells with roles than without (the roles really act).
    LatticeBoundary B0;
    B0.set_voxel_base(&grid, &dens, 0.5, 2.0 * 4.0);
    B0.add_keep_out(ko, true);
    LatticeRegion Rr;
    Rr.nx = Rr.ny = 6;
    Rr.nz = 3;
    Rr.cell_mm = cell;
    Rr.boundary = &B;
    LatticeRegion R0 = Rr;
    R0.boundary = &B0;
    CHECK(latticed_cell_count(Rr) < latticed_cell_count(R0),
          "roles reduce the active cell set");
    // Determinism: the role-aware mask is reproducible bit-for-bit.
    CHECK(lattice_certification_mask(B, grid, dens, 0.5, grid.origin, cell) ==
              mask,
          "role-aware mask is deterministic");
  }

  std::printf("\n%s: %d checks, %d failures\n",
              g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
