// Unit tests for the FREEFORM lattice skin (task 2026-07-30-lattice-skin-
// freeform): the diagrid generalised from analytic faces to the arbitrary
// voxel-derived outer surface of a real optimized part.
//
// Same self-contained CHECK harness as test_lattice_gen.cpp (ARCHITECTURE §4
// locks the dependency set). LATTICE_TMP_DIR is injected by CMake.
//
// The fixture is deliberately CURVED with both convex and concave regions and
// NO analytic base faces: a voxel rasterisation (0.5 mm voxels) of two
// overlapping spheres (their junction is a reentrant — concave — crease) with
// a spherical dimple subtracted from the top (a concave bowl), plus a declared
// bolt keep-out through the body. Every landing on this part carries face ==
// -1, exactly the situation PR 250 left bare (its E2E receipt: skin_struts 0).
//
// Gates (the geometric bars, held at the task's stated numbers):
//   * freeform OFF  => skin_struts == 0 (the boundary-finish behaviour, pinned)
//   * freeform ON   => skin appears; every emitted vertex within 0.05 mm of
//                      the true surface; ZERO vertices inside the keep-out and
//                      min radius >= declared; band rejections occur (the
//                      crease) and are counted; determinism byte-identical;
//                      every primitive closed (boundary_edges == 0 welded);
//                      skin connectivity >= the E3 bar (95% largest component,
//                      <= 1% isolated landings).

#include "topopt/clearance.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <functional>
#include <map>
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
  return !sa.empty() && sa == sb;
}

// Weld an unshared-soup mesh by exact quantised coordinate (1e-6 mm) — what an
// STL reader does on re-import (test_lattice_gen.cpp's helper, verbatim).
static TriangleMesh weld_soup(const TriangleMesh& in) {
  TriangleMesh out;
  std::map<std::array<long long, 3>, int> idx;
  auto key = [](const Vec3& v) {
    return std::array<long long, 3>{(long long)std::llround(v.x * 1e6),
                                    (long long)std::llround(v.y * 1e6),
                                    (long long)std::llround(v.z * 1e6)};
  };
  out.triangles.reserve(in.triangles.size());
  for (const auto& t : in.triangles) {
    std::array<int, 3> nt;
    for (int c = 0; c < 3; ++c) {
      const Vec3& v = in.vertices[t[c]];
      auto k = key(v);
      auto it = idx.find(k);
      if (it == idx.end()) {
        int id = (int)out.vertices.size();
        idx[k] = id;
        out.vertices.push_back(v);
        nt[c] = id;
      } else {
        nt[c] = it->second;
      }
    }
    out.triangles.push_back(nt);
  }
  return out;
}

// ── the curved fixture ───────────────────────────────────────────────────────
// Two spheres (reentrant crease at their junction) minus a dimple bowl, on a
// 0.5 mm voxel grid. Solid extents roughly [2,30]x[2,26]x[2,26] mm.
static constexpr double kVox = 0.5;
static constexpr double kS1cx = 13.0, kS1cy = 14.0, kS1cz = 13.0, kS1r = 11.0;
static constexpr double kS2cx = 25.0, kS2cy = 14.0, kS2cz = 15.0, kS2r = 7.0;
static constexpr double kDimCx = 13.0, kDimCy = 14.0, kDimCz = 27.0, kDimR = 6.0;
static constexpr double kBoltX = 13.0, kBoltY = 14.0, kBoltR = 2.5;

static bool fixture_solid(const Vec3& p) {
  auto d2 = [&](double cx, double cy, double cz) {
    return (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy) +
           (p.z - cz) * (p.z - cz);
  };
  const bool body = d2(kS1cx, kS1cy, kS1cz) <= kS1r * kS1r ||
                    d2(kS2cx, kS2cy, kS2cz) <= kS2r * kS2r;
  const bool dimple = d2(kDimCx, kDimCy, kDimCz) <= kDimR * kDimR;
  // A narrow SLIT into the big sphere (1.0 mm air gap after 0.5 mm voxel
  // quantisation): eroded landings on its two facing walls sit ~1.6 mm apart
  // (inside link range), and a straight chord between them crosses the gap —
  // the deterministic bulge case the band test MUST reject.
  const bool slit =
      p.x < 9.5 && p.y >= 13.5 && p.y < 14.5 && p.z >= 8.0 && p.z < 18.0;
  return body && !dimple && !slit;
}

static VoxelGrid fixture_grid() {
  VoxelGrid g;
  g.nx = 68;  // 34 mm
  g.ny = 56;  // 28 mm
  g.nz = 56;  // 28 mm
  g.spacing = kVox;
  g.origin = {0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  return g;
}

static std::vector<double> fixture_density(const VoxelGrid& g) {
  std::vector<double> d(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const Vec3 c{g.origin.x + (i + 0.5) * g.spacing,
                     g.origin.y + (j + 0.5) * g.spacing,
                     g.origin.z + (k + 0.5) * g.spacing};
        if (fixture_solid(c)) d[g.index(i, j, k)] = 1.0;
      }
  return d;
}

static ClearanceGeometry fixture_bolt() {
  ManualClearanceGeometry mg;
  mg.kind = ClearanceKind::Bolt;
  mg.axis_point = {kBoltX, kBoltY, 13.0};
  mg.axis_dir = {0, 0, 1};
  mg.radius_mm = kBoltR;
  mg.half_length_mm = 16.0;
  ClearanceParams p;  // zero margins: declared radius IS the wall
  p.kind = ClearanceKind::Bolt;
  p.concentric_margin_mm = 0.0;
  p.axial_clearance_mm = 0.0;
  return resolve_clearance_manual(mg, p);
}

int main() {
  const double cell = 2.5;
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
  G.uniform_mm = 0.3;
  G.nseg = 8;

  LatticeSkinSpec S;
  S.mode = LatticeSkinMode::Diagrid;
  S.min_radius_mm = lattice_skin_min_radius_mm(0.4);  // 0.3 mm

  // ---- 1. freeform OFF: the boundary-finish behaviour, pinned --------------
  // (The declared bolt is an analytic Bore face through solid material here, so
  // its collar edges legitimately appear with freeform OFF — what PR 250 built.
  // The pin is that the FREEFORM surface stays bare: zero chords considered.)
  std::uint64_t off_skin_struts = 0;
  {
    MeshSink ms;
    LatticeSkinSpec off = S;
    off.freeform = false;
    const LatticeGenStats st =
        generate_lattice(LatticeGenTopology::Octet, R, G, ms, off, nullptr);
    CHECK(st.landings > 0, "off: the curved part has landings");
    CHECK(st.skin_chords == 0 && st.skin_chords_rejected_band == 0 &&
              st.skin_chords_rejected_projection == 0 &&
              st.skin_chords_clipped_away == 0,
          "off: freeform counters all zero (voxel surface bare)");
    CHECK(st.anchor_nodes == st.landings, "off: every landing anchored");
    off_skin_struts = st.skin_struts;
  }

  // ---- 2. freeform ON: skin appears, all geometric bars hold ---------------
  S.freeform = true;
  struct Chord {
    Vec3 a, b;
    LatticeSkinChordVerdict v;
  };
  std::vector<Chord> chords;
  struct L {
    Vec3 pos;
    double r;
    int face;
  };
  std::vector<L> landings;
  LatticeGenObserver obs;
  obs.on_landing = [&](const Vec3& p, double r, int face) {
    landings.push_back({p, r, face});
  };
  obs.on_skin_chord = [&](const Vec3& a, const Vec3& b,
                          LatticeSkinChordVerdict v) {
    chords.push_back({a, b, v});
  };

  MeshSink ms;
  const LatticeGenStats st =
      generate_lattice(LatticeGenTopology::Octet, R, G, ms, S, &obs);
  const TriangleMesh& m = ms.mesh;

  CHECK(st.skin_struts > off_skin_struts,
        "on: skin edges appear on the freeform surface (beyond the collar)");
  CHECK(st.skin_chords > 0, "on: accepted chords counted");
  CHECK(st.skin_chords_rejected_band > 0,
        "on: the slit's cross-gap chords are band-rejected (bulge)");

  // E4: every emitted vertex within 0.05 mm of the true surface (the full
  // predicate — voxel solid minus keep-out).
  double max_overshoot = 0.0;
  for (const auto& v : m.vertices)
    max_overshoot = std::max(max_overshoot, -B.signed_distance(v));
  CHECK(max_overshoot <= 0.05, "E4: max overshoot <= 0.05 mm");

  // E5: zero vertices inside the declared keep-out; min radius >= declared.
  long long inside = 0;
  double min_rad = 1e30;
  for (const auto& v : m.vertices) {
    if (v.z < -3.0 || v.z > 29.0) continue;
    const double rad = std::hypot(v.x - kBoltX, v.y - kBoltY);
    if (rad < kBoltR + 3.0) min_rad = std::min(min_rad, rad);
    if (rad < kBoltR - 1e-9) ++inside;
  }
  CHECK(inside == 0, "E5: zero vertices inside the declared keep-out");
  CHECK(min_rad >= kBoltR - 1e-9, "E5: min radius >= declared radius");

  // E3: skin-graph connectivity. Skin NODES are the freeform (face == -1)
  // landings, merged by the generator's own dedup rule (near-coincident
  // landings are one skin knot); edges are the accepted chords. Bar stated
  // BEFORE measuring: largest connected component >= 95% of skin nodes,
  // isolated nodes <= 1%.
  {
    std::vector<L> ff;
    for (const auto& l : landings)
      if (l.face < 0) ff.push_back(l);
    // Greedy clustering with the generator's merge radius (deterministic:
    // emission order).
    auto key = [](const Vec3& v) {
      return std::array<long long, 3>{(long long)std::llround(v.x * 1e6),
                                      (long long)std::llround(v.y * 1e6),
                                      (long long)std::llround(v.z * 1e6)};
    };
    std::map<std::array<long long, 3>, int> pos_cluster;
    std::vector<L> reps;
    for (std::size_t i = 0; i < ff.size(); ++i) {
      int cl = -1;
      for (std::size_t c = 0; c < reps.size(); ++c) {
        const double merge =
            std::min(2.0 * std::min(ff[i].r, reps[c].r), 0.3 * cell);
        const double dx = ff[i].pos.x - reps[c].pos.x,
                     dy = ff[i].pos.y - reps[c].pos.y,
                     dz = ff[i].pos.z - reps[c].pos.z;
        if (std::sqrt(dx * dx + dy * dy + dz * dz) < merge) {
          cl = (int)c;
          break;
        }
      }
      if (cl < 0) {
        cl = (int)reps.size();
        reps.push_back(ff[i]);
      }
      pos_cluster.emplace(key(ff[i].pos), cl);
    }
    auto nearest_cluster = [&](const Vec3& p) {
      const auto it = pos_cluster.find(key(p));
      return it == pos_cluster.end() ? -1 : it->second;
    };
    std::vector<int> parent(reps.size());
    for (std::size_t i = 0; i < parent.size(); ++i) parent[i] = (int)i;
    std::function<int(int)> find = [&](int x) {
      while (parent[x] != x) x = parent[x] = parent[parent[x]];
      return x;
    };
    std::vector<char> has_edge(reps.size(), 0);
    for (const auto& c : chords) {
      if (c.v != LatticeSkinChordVerdict::Accepted) continue;
      const int ia = nearest_cluster(c.a), ib = nearest_cluster(c.b);
      if (ia < 0 || ib < 0) continue;
      has_edge[(std::size_t)ia] = has_edge[(std::size_t)ib] = 1;
      parent[find(ia)] = find(ib);
    }
    std::map<int, long long> comp;
    long long isolated = 0;
    for (std::size_t i = 0; i < parent.size(); ++i) {
      ++comp[find((int)i)];
      if (!has_edge[i]) ++isolated;
    }
    long long largest = 0;
    for (const auto& kv : comp) largest = std::max(largest, kv.second);
    const double frac = reps.empty() ? 0.0 : (double)largest / reps.size();
    const double iso_frac = reps.empty() ? 1.0 : (double)isolated / reps.size();
    std::printf("connectivity: %zu freeform landings -> %zu skin nodes, "
                "largest CC %.1f%%, isolated %.2f%%\n",
                ff.size(), reps.size(), 100.0 * frac, 100.0 * iso_frac);
    CHECK(frac >= 0.95, "E3: largest skin component >= 95% of skin nodes");
    CHECK(iso_frac <= 0.01, "E3: isolated skin nodes <= 1%");
  }

  // Sliceability of the shell-less finish: welded, the soup has NO boundary
  // edges (every primitive is a closed solid — the union a slicer accepts,
  // exactly the property PR 201's print and test_lattice_gen pinned).
  {
    const TriangleMesh welded = weld_soup(m);
    const WatertightReport wt = check_watertight(welded);
    CHECK(wt.boundary_edges == 0,
          "skin finish: no boundary edges (every primitive closed)");
  }

  // ---- 3. determinism: streamed rerun is byte-identical --------------------
  {
    const std::string p1 = tmp("freeform_a.stl"), p2 = tmp("freeform_b.stl");
    {
      StreamingStlWriter w(p1);
      generate_lattice(LatticeGenTopology::Octet, R, G, w, S, nullptr);
      w.finish();
    }
    {
      StreamingStlWriter w(p2);
      generate_lattice(LatticeGenTopology::Octet, R, G, w, S, nullptr);
      w.finish();
    }
    CHECK(files_identical(p1, p2), "determinism: rerun byte-identical");
    std::remove(p1.c_str());
    std::remove(p2.c_str());
  }

  std::printf("stats: struts=%llu skin_struts=%llu chords=%llu "
              "rej_band=%llu rej_proj=%llu clipped_away=%llu landings=%llu "
              "max_overshoot=%.6f min_rad=%.3f\n",
              (unsigned long long)st.struts, (unsigned long long)st.skin_struts,
              (unsigned long long)st.skin_chords,
              (unsigned long long)st.skin_chords_rejected_band,
              (unsigned long long)st.skin_chords_rejected_projection,
              (unsigned long long)st.skin_chords_clipped_away,
              (unsigned long long)st.landings, max_overshoot, min_rad);
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
