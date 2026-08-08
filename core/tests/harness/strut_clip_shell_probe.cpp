// strut_clip_shell_probe — S1 and S2 of task 2026-08-08-strut-clip-matches-shell.
//
// THE OBSERVATION THIS EXISTS TO EXPLAIN. The maintainer loaded his latticed
// variants in a slicer and found strut ends standing proud of the outer surface
// — regularly spaced teeth, and his discriminating detail is that they appear
// ONLY ON EDGES: "on flat surfaces it is impossible to see any lattices — but it
// is on edges where they creep out beyond whatever is covering them."
//
// THE TWO SURFACES. The latticed file carries the solid SHELL and the strut
// soup, and they were extracted from DIFFERENT surfaces:
//   SHELL   run_job.cpp's export_latticed_variant pushes `variant.v3.mesh` —
//           marching cubes over the physical density, whose vertices lie on the
//           segments between voxel CENTRES.
//   STRUTS  lattice_gen.cpp:353 clips every centreline to
//           `LatticeBoundary::signed_distance >= radius`, whose base term was
//           the distance to the union of solid voxel CUBES.
// On a flat face the two coincide EXACTLY — the 0.5 crossing between a solid
// centre and a void centre falls on the shared cube face. At a CONVEX EDGE the
// isosurface chamfers the cube union and lies strictly inside it. Edges only,
// faces clean.
//
// WHAT THIS PROBE MEASURES:
//   S1a  the protrusion — for every emitted lattice vertex, its signed distance
//        OUTSIDE the shell (max, mean, count), and what output.smooth_factor
//        does and does not change;
//   S1b  the surface gap directly — the isosurface's inset below the cube-union
//        boundary as a function of DISTANCE TO THE NEAREST CONVEX EDGE, which is
//        what turns "a convex-edge phenomenon" into a measurement;
//   S2   the three candidate fixes on the same fixture, each with what it costs:
//        emitted lattice volume, latticed voxel count, and generation wall time.
//
// It is a HARNESS, not a ctest: it prints tables and writes evidence. The ctest
// that must fail-then-pass is tests/unit/test_lattice_clip_shell.cpp.
//
// Build (repo root, after the library is built):
//   c++ -std=c++17 -O2 -I core/include -I core/tests/harness \
//       core/tests/harness/strut_clip_shell_probe.cpp core/build/libtopopt.a \
//       -o core/build/strut_clip_shell_probe
//   ./core/build/strut_clip_shell_probe [evidence-dir]

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/lattice.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/mesh_distance.hpp"
#include "topopt/voxel.hpp"

using topopt::LatticeBoundary;
using topopt::LatticeGenStats;
using topopt::LatticeGenTopology;
using topopt::LatticeRadiusField;
using topopt::LatticeRegion;
using topopt::LatticeSkinMode;
using topopt::LatticeSkinSpec;
using topopt::MeshDistance;
using topopt::ResampleInterp;
using topopt::TriangleMesh;
using topopt::TriangleSink;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

namespace {

// HIS voxel — resolution 128 on M2_verticalStand — so every millimetre below is
// directly comparable with the part he printed.
constexpr double kHisSpacingMm = 1.705;
// PLA, for turning a lost lattice volume into a lost mass.
constexpr double kPlaDensityGPerCm3 = 1.24;

double now_s() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

struct Fixture {
  VoxelGrid grid;
  std::vector<double> density;
  int lo = 0, hi = 0;  // the solid block's voxel index range (all three axes)
  bool notched = false;
};

Fixture make_block(int n, int lo, int hi, bool notch, double spacing) {
  Fixture f;
  f.lo = lo;
  f.hi = hi;
  f.notched = notch;
  f.grid.nx = f.grid.ny = f.grid.nz = n;
  f.grid.spacing = spacing;
  f.grid.origin = Vec3{0.0, 0.0, 0.0};
  f.grid.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
  f.density.assign(f.grid.tags.size(), 0.0);
  const int mid = (lo + hi) / 2;
  for (int k = 0; k < n; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i) {
        bool in = i >= lo && i <= hi && j >= lo && j <= hi && k >= lo && k <= hi;
        if (in && notch && i > mid && j > mid && k > mid) in = false;
        if (!in) continue;
        f.grid.tags[f.grid.index(i, j, k)] = VoxelTag::Interior;
        f.density[f.grid.index(i, j, k)] = 1.0;
      }
  return f;
}

// A sink that measures every vertex against `md`. Positive = OUTSIDE the shell.
struct ProtrusionSink : TriangleSink {
  const MeshDistance* md = nullptr;
  double max_out = 0.0;
  double sum_out = 0.0;
  long long n_out = 0;
  long long n_total = 0;
  Vec3 worst{};
  void one(const Vec3& v) {
    ++n_total;
    const double out = -md->signed_distance(v);
    if (out > 0.0) {
      ++n_out;
      sum_out += out;
      if (out > max_out) {
        max_out = out;
        worst = v;
      }
    }
  }
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
    one(a);
    one(b);
    one(c);
  }
};

struct CaseResult {
  double max_out = 0.0;
  double mean_out = 0.0;
  long long n_out = 0;
  long long n_total = 0;
  Vec3 worst{};
  LatticeGenStats gs{};
  double gen_seconds = 0.0;
  long long latticed_voxels = 0;
  // Kept interior-strut CENTRELINE length. `gs.interior_volume_mm3` is computed
  // at the radius the generator emitted, which makes it useless for costing the
  // erosion candidate (S2b models the erosion by inflating the radius, so its
  // volume would go UP by the inflation rather than DOWN by the lost lattice).
  // Length is the radius-free measure of how much lattice each candidate keeps,
  // and pi*r^2*length re-prices it all at the SAME strut radius.
  double kept_length_mm = 0.0;
};

LatticeRegion region_for(const VoxelGrid& g, double cell_mm,
                         const LatticeBoundary* B) {
  LatticeRegion R;
  R.origin = g.origin;
  R.cell_mm = cell_mm;
  R.nx = std::max(1, static_cast<int>(std::ceil(g.nx * g.spacing / cell_mm)));
  R.ny = std::max(1, static_cast<int>(std::ceil(g.ny * g.spacing / cell_mm)));
  R.nz = std::max(1, static_cast<int>(std::ceil(g.nz * g.spacing / cell_mm)));
  R.boundary = B;
  return R;
}

// A sink that does nothing but count — for TIMING the generator alone.
// `run_case` below times generation with the protrusion measurement attached,
// which is the right number for "what does a run cost" but the WRONG one for
// "what does the clip cost", because the measurement is the same on both sides
// and swamps the difference. This isolates the clip.
struct CountingSink : TriangleSink {
  long long n = 0;
  void add_triangle(const Vec3&, const Vec3&, const Vec3&) override { ++n; }
};

double time_generation_only(const Fixture& f, const LatticeBoundary& B,
                            double cell_mm, double radius_mm, int reps) {
  LatticeRegion R = region_for(f.grid, cell_mm, &B);
  LatticeRadiusField G;
  G.uniform_mm = radius_mm;
  LatticeSkinSpec skin;
  skin.mode = LatticeSkinMode::None;
  double best = 1e30;  // best-of-N: the minimum is the least noisy estimator
  for (int i = 0; i < reps; ++i) {
    CountingSink s;
    const double t0 = now_s();
    topopt::generate_lattice(LatticeGenTopology::Octet, R, G, s, skin);
    best = std::min(best, now_s() - t0);
  }
  return best;
}

CaseResult run_case(const Fixture& f, const LatticeBoundary& B,
                    const MeshDistance& md, double cell_mm, double radius_mm) {
  CaseResult r;
  LatticeRegion R = region_for(f.grid, cell_mm, &B);
  LatticeRadiusField G;
  G.uniform_mm = radius_mm;
  LatticeSkinSpec skin;
  skin.mode = LatticeSkinMode::None;
  ProtrusionSink sink;
  sink.md = &md;
  topopt::LatticeGenObserver obs;
  double kept = 0.0;
  obs.on_element = [&kept](topopt::LatticeGenElement k, const Vec3& a,
                           const Vec3& b, double) {
    if (k != topopt::LatticeGenElement::InteriorStrut) return;
    const double dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z;
    kept += std::sqrt(dx * dx + dy * dy + dz * dz);
  };
  const double t0 = now_s();
  r.gs = topopt::generate_lattice(LatticeGenTopology::Octet, R, G, sink, skin,
                                  &obs);
  r.gen_seconds = now_s() - t0;
  r.kept_length_mm = kept;
  r.max_out = sink.max_out;
  r.mean_out = sink.n_out ? sink.sum_out / static_cast<double>(sink.n_out) : 0.0;
  r.n_out = sink.n_out;
  r.n_total = sink.n_total;
  r.worst = sink.worst;
  // The CERTIFIED set under the same boundary — a fix that quietly moved which
  // voxels are certified latticed would show up here and nowhere else.
  const std::vector<char> mask = topopt::lattice_certification_mask(
      B, f.grid, f.density, 0.5, f.grid.origin, cell_mm);
  for (const char c : mask) r.latticed_voxels += (c ? 1 : 0);
  return r;
}

// ── S1b. The isosurface's inset below the CUBE-UNION boundary, as a function of
// distance to the nearest CONVEX EDGE.
//
// The fixture's solid set is an axis-aligned block, so its cube union is the box
// [lo*h, (hi+1)*h]^3 EXACTLY and the distance from a surface point to the nearest
// box edge is closed form: on a face, it is the smaller of the two in-plane
// distances to that face's borders. No sampling, no approximation — which is what
// lets the table below say "at 2 voxels from an edge the inset is 0" and mean it.
struct EdgeBucket {
  double upper_voxels;  // bucket covers d_edge/h < upper_voxels
  double max_inset = 0.0;
  long long n = 0;
};

std::vector<EdgeBucket> isosurface_inset_by_edge_distance(
    const Fixture& f, const MeshDistance& md, int m) {
  std::vector<EdgeBucket> b = {{0.25}, {0.5}, {1.0}, {2.0}, {1e30}};
  const double h = f.grid.spacing;
  const double c0 = f.lo * h;
  const double c1 = (f.hi + 1) * h;
  // Six faces of the box; sample each on an (m+1)^2 lattice including borders.
  for (int axis = 0; axis < 3; ++axis)
    for (int side = 0; side < 2; ++side)
      for (int q = 0; q <= m; ++q)
        for (int p = 0; p <= m; ++p) {
          const double u = c0 + (c1 - c0) * static_cast<double>(p) / m;
          const double v = c0 + (c1 - c0) * static_cast<double>(q) / m;
          const double s = side == 0 ? c0 : c1;
          Vec3 pt;
          if (axis == 0) pt = Vec3{s, u, v};
          else if (axis == 1) pt = Vec3{u, s, v};
          else pt = Vec3{u, v, s};
          // Distance to the nearest box EDGE, in voxels.
          const double d_edge =
              std::min(std::min(u - c0, c1 - u), std::min(v - c0, c1 - v)) / h;
          const double inset = -md.signed_distance(pt);  // >0: shell is inside
          for (EdgeBucket& bk : b)
            if (d_edge < bk.upper_voxels) {
              ++bk.n;
              if (inset > bk.max_inset) bk.max_inset = inset;
              break;
            }
        }
  return b;
}

std::string fmt(double v) {
  char s[64];
  std::snprintf(s, sizeof(s), "%.6f", v);
  return s;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string evidence = argc > 1 ? argv[1] : "";
  const double h = kHisSpacingMm;
  const double cell_mm = 4.0 * h;   // 6.82 mm — ~6 cells across the block
  // A radius in the middle of his measured strut range (0.225-0.384 mm), so the
  // protrusion is a property of the SURFACE MISMATCH and not of a fat strut.
  const double radius_mm = 0.30;

  std::printf(
      "strut_clip_shell_probe — task 2026-08-08-strut-clip-matches-shell\n"
      "  voxel spacing   %.4f mm (his: resolution 128 on M2_verticalStand)\n"
      "  lattice cell    %.4f mm\n"
      "  strut radius    %.4f mm (his measured range 0.225-0.384 mm)\n\n",
      h, cell_mm, radius_mm);

  std::string csv =
      "case,clip,shell_measured_against,smooth_factor,max_out_mm,mean_out_mm,"
      "n_out,n_total,struts,clipped,dropped,interior_volume_mm3,lattice_mass_g,"
      "latticed_voxels,gen_seconds\n";
  std::string gapcsv = "case,edge_distance_voxels_below,samples,max_inset_mm\n";

  struct Case {
    const char* name;
    bool notch;
  };
  const Case cases[] = {{"block", false}, {"notched_block", true}};

  for (const Case& C : cases) {
    const Fixture f = make_block(40, 8, 31, C.notch, h);
    const VoxelGrid& g = f.grid;

    // THE SHELL, exactly as the latticed export pushes it: v3.mesh is
    // keep_largest_component(marching_cubes(grid, density, 0.5)) — voxelize.cpp
    // :735 + :813. output.smooth_factor does NOT enter here.
    const TriangleMesh shell = topopt::keep_largest_component(
        topopt::marching_cubes(g, f.density, 0.5));
    const MeshDistance md(shell);

    std::printf("=== %s ===\n", C.name);
    std::printf("  shell (v3.mesh)  %zu verts, %zu tris, watertight=%d, "
                "inward_wound=%d\n",
                shell.vertices.size(), shell.triangles.size(),
                topopt::check_watertight(shell).watertight ? 1 : 0,
                md.inward_wound() ? 1 : 0);

    // ── S1b (block only: its cube union is an exact box, so the edge distance
    // is closed form).
    if (!C.notch) {
      const std::vector<EdgeBucket> bk =
          isosurface_inset_by_edge_distance(f, md, 240);
      std::printf(
          "  S1b  isosurface inset BELOW the cube-union boundary, by distance "
          "to the nearest convex edge:\n");
      for (const EdgeBucket& x : bk) {
        char lbl[32];
        if (x.upper_voxels > 1e29) std::snprintf(lbl, sizeof(lbl), ">= 2.00 vox");
        else std::snprintf(lbl, sizeof(lbl), "<  %.2f vox", x.upper_voxels);
        std::printf("        %-12s  samples %-8lld  max inset %s mm\n", lbl,
                    x.n, fmt(x.max_inset).c_str());
        gapcsv += std::string(C.name) + "," +
                  (x.upper_voxels > 1e29 ? "inf" : fmt(x.upper_voxels)) + "," +
                  std::to_string(x.n) + "," + fmt(x.max_inset) + "\n";
      }
    }

    // Every candidate priced at the SAME strut radius, from the kept centreline
    // length, so the erosion candidate is not credited for its own inflation.
    auto volume_at_r = [radius_mm](const CaseResult& r) {
      return 3.14159265358979323846 * radius_mm * radius_mm * r.kept_length_mm;
    };
    auto row = [&](const char* clip, const char* against, int sf,
                   const CaseResult& r) {
      const double vol = volume_at_r(r);
      const double mass_g = vol * kPlaDensityGPerCm3 / 1000.0;
      csv += std::string(C.name) + "," + clip + "," + against + "," +
             std::to_string(sf) + "," + fmt(r.max_out) + "," +
             fmt(r.mean_out) + "," + std::to_string(r.n_out) + "," +
             std::to_string(r.n_total) + "," + std::to_string(r.gs.struts) +
             "," + std::to_string(r.gs.clipped_struts) + "," +
             std::to_string(r.gs.dropped_struts) + "," + fmt(vol) + "," +
             fmt(mass_g) + "," + std::to_string(r.latticed_voxels) + "," +
             fmt(r.gen_seconds) + "\n";
    };

    // ── S1a: PRODUCTION-AS-WAS — clip to the voxel-cube union.
    LatticeBoundary B_cube;
    B_cube.set_voxel_base(&g, &f.density, 0.5, 2.0 * cell_mm);
    const CaseResult cube = run_case(f, B_cube, md, cell_mm, radius_mm);
    std::printf(
        "  S1a  clip = voxel-cube union (as shipped): max %s mm, mean %s mm, "
        "%lld of %lld vertices OUTSIDE the shell\n"
        "        struts %llu, clipped %llu, dropped %llu, interior %s mm3, "
        "gen %s s, latticed voxels %lld\n",
        fmt(cube.max_out).c_str(), fmt(cube.mean_out).c_str(), cube.n_out,
        cube.n_total, (unsigned long long)cube.gs.struts,
        (unsigned long long)cube.gs.clipped_struts,
        (unsigned long long)cube.gs.dropped_struts,
        fmt(volume_at_r(cube)).c_str(), fmt(cube.gen_seconds).c_str(),
        cube.latticed_voxels);
    row("cube-union", "v3.mesh", 1, cube);

    // ── S1a / S2c: what output.smooth_factor actually changes. The LATTICED
    // export pushes v3.mesh (factor 1) whatever the job says, so these rows are
    // counterfactual — they measure the shell the SOLID export would write.
    for (int sf = 1; sf <= 3; ++sf) {
      const TriangleMesh shell_sf =
          topopt::keep_largest_component(topopt::marching_cubes_resampled(
              g.nx, g.ny, g.nz, g.spacing, g.origin, f.density, 0.5, sf,
              ResampleInterp::Tricubic));
      const MeshDistance md_sf(shell_sf);
      const CaseResult r = run_case(f, B_cube, md_sf, cell_mm, radius_mm);
      std::printf(
          "  S2c  same struts vs a TRICUBIC smooth_factor=%d shell: max %s mm, "
          "%lld of %lld outside\n",
          sf, fmt(r.max_out).c_str(), r.n_out, r.n_total);
      row("cube-union", "tricubic", sf, r);
    }

    // ── S2a: clip against the SHELL the file carries.
    LatticeBoundary B_shell;
    B_shell.set_voxel_base(&g, &f.density, 0.5, 2.0 * cell_mm);
    B_shell.set_shell_base(&shell);
    const CaseResult sh = run_case(f, B_shell, md, cell_mm, radius_mm);
    std::printf(
        "  S2a  clip = the exported SHELL: max %s mm, %lld of %lld outside\n"
        "        struts %llu (%+lld), dropped %llu (%+lld), interior %s mm3 "
        "(%+.3f%%), gen %s s (%.2fx), latticed voxels %lld (%+lld)\n",
        fmt(sh.max_out).c_str(), sh.n_out, sh.n_total,
        (unsigned long long)sh.gs.struts,
        (long long)sh.gs.struts - (long long)cube.gs.struts,
        (unsigned long long)sh.gs.dropped_struts,
        (long long)sh.gs.dropped_struts - (long long)cube.gs.dropped_struts,
        fmt(volume_at_r(sh)).c_str(),
        100.0 * (volume_at_r(sh) / volume_at_r(cube) - 1.0),
        fmt(sh.gen_seconds).c_str(), sh.gen_seconds / cube.gen_seconds,
        sh.latticed_voxels, sh.latticed_voxels - cube.latticed_voxels);
    row("shell", "v3.mesh", 1, sh);

    // ── S2b: keep the cube union, ERODE by the measured worst-case inset. The
    // erosion is applied as extra strut radius, which is exactly what eroding
    // the allowed region by a constant does to this clip.
    const double erode = h / std::sqrt(3.0);  // the corner inset, closed form
    LatticeBoundary B_er;
    B_er.set_voxel_base(&g, &f.density, 0.5, 2.0 * cell_mm);
    const CaseResult er =
        run_case(f, B_er, md, cell_mm, radius_mm + erode);
    std::printf(
        "  S2b  cube union eroded by %s mm: max %s mm, %lld of %lld outside\n"
        "        struts %llu (%+lld), dropped %llu (%+lld), interior %s mm3 "
        "(%+.3f%%), gen %s s (%.2fx)\n\n",
        fmt(erode).c_str(), fmt(er.max_out).c_str(), er.n_out, er.n_total,
        (unsigned long long)er.gs.struts,
        (long long)er.gs.struts - (long long)cube.gs.struts,
        (unsigned long long)er.gs.dropped_struts,
        (long long)er.gs.dropped_struts - (long long)cube.gs.dropped_struts,
        fmt(volume_at_r(er)).c_str(),
        100.0 * (volume_at_r(er) / volume_at_r(cube) - 1.0),
        fmt(er.gen_seconds).c_str(), er.gen_seconds / cube.gen_seconds);
    row("cube-union-eroded", "v3.mesh", 1, er);

    // ── S2(a) COST, isolated. The rows above time generation WITH the
    // protrusion measurement attached, which is identical on both sides and
    // hides the thing being priced. These three time the generator alone,
    // best-of-5, into a counting sink.
    const double t_cube = time_generation_only(f, B_cube, cell_mm, radius_mm, 5);
    const double t_shell = time_generation_only(f, B_shell, cell_mm, radius_mm, 5);
    std::printf(
        "  S2a  GENERATOR ALONE (best of 5, counting sink): cube union %s s, "
        "shell %s s  =>  %.2fx\n\n",
        fmt(t_cube).c_str(), fmt(t_shell).c_str(), t_shell / t_cube);
  }

  if (!evidence.empty()) {
    struct Out {
      const char* name;
      const std::string* body;
    };
    const Out outs[] = {{"/s1_protrusion.csv", &csv},
                        {"/s1b_surface_gap.csv", &gapcsv}};
    for (const Out& o : outs) {
      const std::string p = evidence + o.name;
      if (FILE* fp = std::fopen(p.c_str(), "w")) {
        std::fwrite(o.body->data(), 1, o.body->size(), fp);
        std::fclose(fp);
        std::printf("wrote %s\n", p.c_str());
      }
    }
  }
  return 0;
}
