// lattice_skin_freeform_probe.cpp — measurement harness (NOT a CI test) for the
// FREEFORM lattice skin (task 2026-07-30-lattice-skin-freeform).
//
// MEASUREMENT ONLY: generates a CURVED voxel-based part (no analytic base
// faces — every outer landing is freeform) with the REAL production generator
// and measures bars E2/E3/E4/E5/E6/E7/E10 from the emitted geometry.
//
// FIXTURE (voxel base, 0.5 mm voxels, ~64 x 48 x 40 mm):
//   * two overlapping spheres (r 17 + r 11) — curved almost everywhere, with a
//     REENTRANT CREASE at their junction (concave);
//   * a spherical dimple bowl carved into the top (concave);
//   * a narrow slit (1.0 mm air gap) — the deterministic bulge-rejection case;
//   * a declared 6.000 mm bolt keep-out (protected feature, zero margin).
//
// Modes:
//   run <outdir> <cell_mm> <on|off> [graded]
// "off" is the boundary-finish behaviour (PR 250 — freeform skin disarmed):
// the E7 BEFORE timing. One cell size per process so ru_maxrss is
// per-configuration (E6), matching PR 250's B8 discipline.

#include "topopt/clearance.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <sys/resource.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

using namespace topopt;

// ── the fixture ──────────────────────────────────────────────────────────────
static constexpr double kVox = 0.5;
static constexpr double kBoltX = 22.0, kBoltY = 20.0, kBoltR = 3.0;

static bool fixture_solid(const Vec3& p) {
  auto d2 = [&](double cx, double cy, double cz) {
    return (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy) +
           (p.z - cz) * (p.z - cz);
  };
  const bool body = d2(30, 24, 20) <= 17.0 * 17.0 || d2(50, 26, 22) <= 11.0 * 11.0;
  const bool dimple = d2(30, 24, 41) <= 9.0 * 9.0;
  const bool slit = p.x < 12.0 && p.y >= 23.5 && p.y < 24.5 && p.z >= 12.0 &&
                    p.z < 30.0;
  return body && !dimple && !slit;
}

static VoxelGrid fixture_grid() {
  VoxelGrid g;
  g.nx = 128;
  g.ny = 96;
  g.nz = 80;
  g.spacing = kVox;
  g.origin = {0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  return g;
}

static std::vector<double> fixture_density(const VoxelGrid& g) {
  std::vector<double> d(static_cast<std::size_t>(g.nx) * g.ny * g.nz, 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const Vec3 c{(i + 0.5) * g.spacing, (j + 0.5) * g.spacing,
                     (k + 0.5) * g.spacing};
        if (fixture_solid(c)) d[g.index(i, j, k)] = 1.0;
      }
  return d;
}

static ClearanceGeometry fixture_bolt() {
  ManualClearanceGeometry mg;
  mg.kind = ClearanceKind::Bolt;
  mg.axis_point = {kBoltX, kBoltY, 20.0};
  mg.axis_dir = {0, 0, 1};
  mg.radius_mm = kBoltR;
  mg.half_length_mm = 25.0;
  ClearanceParams p;  // zero margins: the declared radius IS the wall
  p.kind = ClearanceKind::Bolt;
  p.concentric_margin_mm = 0.0;
  p.axial_clearance_mm = 0.0;
  return resolve_clearance_manual(mg, p);
}

int main(int argc, char** argv) {
  if (argc < 5) {
    std::fprintf(stderr, "usage: %s run <outdir> <cell_mm> <on|off> [graded]\n",
                 argv[0]);
    return 2;
  }
  const std::string outdir = argv[2];
  const double cell = std::atof(argv[3]);
  const bool freeform = std::strcmp(argv[4], "on") == 0;
  const bool graded = (argc > 5 && std::strcmp(argv[5], "graded") == 0);

  const VoxelGrid grid = fixture_grid();
  const std::vector<double> dens = fixture_density(grid);

  LatticeBoundary B;
  B.set_voxel_base(&grid, &dens, 0.5, 2.0 * cell);
  B.add_keep_out(fixture_bolt(), /*collar=*/true);

  LatticeRegion R;
  R.origin = grid.origin;
  R.cell_mm = cell;
  R.nx = (int)std::ceil(grid.nx * grid.spacing / cell);
  R.ny = (int)std::ceil(grid.ny * grid.spacing / cell);
  R.nz = (int)std::ceil(grid.nz * grid.spacing / cell);
  R.boundary = &B;

  LatticeRadiusField G;
  G.nseg = 8;
  if (graded)
    G.field = [](Vec3 p) {
      const double t = std::min(1.0, std::max(0.0, p.z / 40.0));
      return 0.3 + 0.6 * t;  // 0.3 -> 0.9 mm across the height
    };
  else
    G.uniform_mm = 0.5;

  LatticeSkinSpec S;
  S.mode = LatticeSkinMode::Diagrid;
  S.min_radius_mm = lattice_skin_min_radius_mm(0.8);  // stated 0.8 mm width
  S.freeform = freeform;

  const std::string name = std::string(freeform ? "on" : "off") +
                           (graded ? "_graded" : "") + "_" +
                           std::to_string((int)cell) + "mm";
  const std::string stl_path = outdir + "/freeform_" + name + ".stl";

  // (1) STREAMED write, no observer — the E6 RSS + E7 wall-time path.
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
  long stl_bytes = 0;
  {
    std::ifstream f(stl_path, std::ios::binary | std::ios::ate);
    stl_bytes = f ? (long)f.tellg() : -1;
  }

  // (2) E10: streamed rerun, byte-compare (paid before any measurement copy).
  bool identical = false;
  {
    const std::string stl2 = outdir + "/freeform_" + name + "_rerun.stl";
    {
      StreamingStlWriter w(stl2);
      generate_lattice(LatticeGenTopology::Octet, R, G, w, S, nullptr);
      w.finish();
    }
    std::ifstream fa(stl_path, std::ios::binary), fb(stl2, std::ios::binary);
    std::string sa((std::istreambuf_iterator<char>(fa)), {});
    std::string sb((std::istreambuf_iterator<char>(fb)), {});
    identical = !sa.empty() && sa == sb;
    std::remove(stl2.c_str());
  }

  // (3) In-memory copy WITH the observer for the E2/E3/E4/E5 measurements
  // (test_lattice_gen proves streamed == buffered).
  struct L {
    Vec3 pos;
    double r;
    int face;
  };
  struct Chord {
    Vec3 a, b;
    LatticeSkinChordVerdict v;
  };
  std::vector<L> landings;
  std::vector<Chord> chords;
  LatticeGenObserver obs;
  obs.on_landing = [&](const Vec3& p, double r, int face) {
    landings.push_back({p, r, face});
  };
  obs.on_skin_chord = [&](const Vec3& a, const Vec3& b,
                          LatticeSkinChordVerdict v) {
    chords.push_back({a, b, v});
  };
  MeshSink ms;
  generate_lattice(LatticeGenTopology::Octet, R, G, ms, S, &obs);
  const TriangleMesh& m = ms.mesh;

  // E4: max overshoot past the true surface, over EVERY emitted vertex.
  double max_overshoot = 0.0;
  for (const auto& v : m.vertices)
    max_overshoot = std::max(max_overshoot, -B.signed_distance(v));

  // E5: keep-out intrusion.
  long long inside = 0;
  double min_rad = 1e30;
  for (const auto& v : m.vertices) {
    if (v.z < -5.0 || v.z > 45.0) continue;
    const double rad = std::hypot(v.x - kBoltX, v.y - kBoltY);
    if (rad < kBoltR + 4.0) min_rad = std::min(min_rad, rad);
    if (rad < kBoltR - 1e-9) ++inside;
  }

  // E3: skin graph = deduped freeform landings + accepted chords; also the
  // accepted chord LENGTH distribution.
  std::size_t n_ff = 0, n_nodes = 0;
  double cc_frac = 0.0, iso_frac = 0.0;
  double len_min = 0.0, len_med = 0.0, len_p99 = 0.0, len_max = 0.0;
  {
    std::vector<L> ff;
    for (const auto& l : landings)
      if (l.face < 0) ff.push_back(l);
    n_ff = ff.size();
    auto key = [](const Vec3& v) {
      return std::array<long long, 3>{(long long)std::llround(v.x * 1e6),
                                      (long long)std::llround(v.y * 1e6),
                                      (long long)std::llround(v.z * 1e6)};
    };
    // Greedy clustering with the generator's merge rule, on a coarse spatial
    // hash so the 2 mm configuration stays tractable.
    std::map<std::array<long long, 3>, std::vector<int>> cells;
    auto ckey = [&](const Vec3& v) {
      const double h = 1.0;
      return std::array<long long, 3>{(long long)std::floor(v.x / h),
                                      (long long)std::floor(v.y / h),
                                      (long long)std::floor(v.z / h)};
    };
    std::vector<L> reps;
    std::map<std::array<long long, 3>, int> pos_cluster;
    for (std::size_t i = 0; i < ff.size(); ++i) {
      int cl = -1;
      const auto ck = ckey(ff[i].pos);
      for (long long dx = -1; dx <= 1 && cl < 0; ++dx)
        for (long long dy = -1; dy <= 1 && cl < 0; ++dy)
          for (long long dz = -1; dz <= 1 && cl < 0; ++dz) {
            const auto it =
                cells.find({ck[0] + dx, ck[1] + dy, ck[2] + dz});
            if (it == cells.end()) continue;
            for (const int c : it->second) {
              const double merge = std::min(
                  2.0 * std::min(ff[i].r, reps[(std::size_t)c].r), 0.3 * cell);
              const double ddx = ff[i].pos.x - reps[(std::size_t)c].pos.x,
                           ddy = ff[i].pos.y - reps[(std::size_t)c].pos.y,
                           ddz = ff[i].pos.z - reps[(std::size_t)c].pos.z;
              if (std::sqrt(ddx * ddx + ddy * ddy + ddz * ddz) < merge) {
                cl = c;
                break;
              }
            }
          }
      if (cl < 0) {
        cl = (int)reps.size();
        reps.push_back(ff[i]);
        cells[ck].push_back(cl);
      }
      pos_cluster.emplace(key(ff[i].pos), cl);
    }
    n_nodes = reps.size();
    std::vector<int> parent(reps.size());
    for (std::size_t i = 0; i < parent.size(); ++i) parent[i] = (int)i;
    auto find = [&](int x) {
      while (parent[(std::size_t)x] != x)
        x = parent[(std::size_t)x] = parent[(std::size_t)parent[(std::size_t)x]];
      return x;
    };
    std::vector<char> has_edge(reps.size(), 0);
    std::vector<double> lens;
    for (const auto& c : chords) {
      if (c.v != LatticeSkinChordVerdict::Accepted) continue;
      lens.push_back(std::sqrt((c.a.x - c.b.x) * (c.a.x - c.b.x) +
                               (c.a.y - c.b.y) * (c.a.y - c.b.y) +
                               (c.a.z - c.b.z) * (c.a.z - c.b.z)));
      const auto ia = pos_cluster.find(key(c.a));
      const auto ib = pos_cluster.find(key(c.b));
      if (ia == pos_cluster.end() || ib == pos_cluster.end()) continue;
      has_edge[(std::size_t)ia->second] = 1;
      has_edge[(std::size_t)ib->second] = 1;
      parent[(std::size_t)find(ia->second)] = find(ib->second);
    }
    std::map<int, long long> comp;
    long long isolated = 0;
    for (std::size_t i = 0; i < parent.size(); ++i) {
      ++comp[find((int)i)];
      if (!has_edge[i]) ++isolated;
    }
    long long largest = 0;
    for (const auto& kv : comp) largest = std::max(largest, kv.second);
    cc_frac = reps.empty() ? 0.0 : (double)largest / reps.size();
    iso_frac = reps.empty() ? 0.0 : (double)isolated / reps.size();
    if (!lens.empty()) {
      std::sort(lens.begin(), lens.end());
      len_min = lens.front();
      len_max = lens.back();
      len_med = lens[lens.size() / 2];
      len_p99 = lens[std::min(lens.size() - 1,
                              (std::size_t)(0.99 * (double)lens.size()))];
    }
  }

  // E2: the skin must dress CURVED regions, not just flat patches — the
  // fraction of accepted chords whose local surface normal (FD gradient of the
  // exact SDF at the chord midpoint) is > 10 degrees off EVERY grid axis.
  long long off_axis = 0, accepted = 0;
  for (const auto& c : chords) {
    if (c.v != LatticeSkinChordVerdict::Accepted) continue;
    ++accepted;
    const Vec3 mid{0.5 * (c.a.x + c.b.x), 0.5 * (c.a.y + c.b.y),
                   0.5 * (c.a.z + c.b.z)};
    const double e = 1e-3;
    const double gx = B.signed_distance({mid.x + e, mid.y, mid.z}) -
                      B.signed_distance({mid.x - e, mid.y, mid.z});
    const double gy = B.signed_distance({mid.x, mid.y + e, mid.z}) -
                      B.signed_distance({mid.x, mid.y - e, mid.z});
    const double gz = B.signed_distance({mid.x, mid.y, mid.z + e}) -
                      B.signed_distance({mid.x, mid.y, mid.z - e});
    const double n = std::sqrt(gx * gx + gy * gy + gz * gz);
    if (!(n > 0.0)) continue;
    const double mx =
        std::max({std::fabs(gx), std::fabs(gy), std::fabs(gz)}) / n;
    if (mx < std::cos(10.0 * M_PI / 180.0)) ++off_axis;
  }

  std::printf("MODE=%s CELL=%g GRADED=%d\n", freeform ? "on" : "off", cell,
              graded ? 1 : 0);
  std::printf("STL=%s BYTES=%ld\n", stl_path.c_str(), stl_bytes);
  std::printf("TRIANGLES=%llu STRUTS=%llu NODES=%llu CELLS=%lld LANDINGS=%llu "
              "ANCHORS=%llu\n",
              (unsigned long long)st.triangles, (unsigned long long)st.struts,
              (unsigned long long)st.nodes, st.latticed_cells,
              (unsigned long long)st.landings,
              (unsigned long long)st.anchor_nodes);
  std::printf("SKIN_STRUTS=%llu SKIN_CHORDS=%llu REJ_BAND=%llu REJ_PROJ=%llu "
              "CLIPPED_AWAY=%llu UNCERT=%lld\n",
              (unsigned long long)st.skin_struts,
              (unsigned long long)st.skin_chords,
              (unsigned long long)st.skin_chords_rejected_band,
              (unsigned long long)st.skin_chords_rejected_projection,
              (unsigned long long)st.skin_chords_clipped_away,
              st.uncertified_spans_dropped);
  std::printf("E2_ACCEPTED_CHORDS=%lld E2_OFF_AXIS=%lld E2_OFF_AXIS_FRAC=%.3f\n",
              accepted, off_axis,
              accepted ? (double)off_axis / (double)accepted : 0.0);
  std::printf("E3_FREEFORM_LANDINGS=%zu E3_SKIN_NODES=%zu E3_LARGEST_CC=%.4f "
              "E3_ISOLATED_FRAC=%.4f\n",
              n_ff, n_nodes, cc_frac, iso_frac);
  std::printf("E3_EDGE_LEN_MM min=%.3f median=%.3f p99=%.3f max=%.3f\n",
              len_min, len_med, len_p99, len_max);
  std::printf("E4_MAX_OVERSHOOT_MM=%.6f\n", max_overshoot);
  std::printf("E5_INSIDE_VERTICES=%lld E5_MIN_RADIUS=%.3f (declared %.3f)\n",
              inside, min_rad, kBoltR);
  std::printf("E9_INTERIOR_MM3=%.1f E9_SKIN_MM3=%.1f E9_RIM_MM3=%.1f\n",
              st.interior_volume_mm3, st.skin_volume_mm3, st.rim_volume_mm3);
  std::printf("E10_BYTE_IDENTICAL=%d\n", identical ? 1 : 0);
  std::printf("E6_PEAK_RSS_BYTES=%ld E7_GEN_SECONDS=%.3f\n", ru.ru_maxrss,
              gen_s);
  return 0;
}
