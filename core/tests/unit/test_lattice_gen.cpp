// Unit tests for the production strut-lattice generator + streaming writers
// (handoff 2026-07-28-lattice-generation-production).
//
// No third-party test framework (ARCHITECTURE §4 locks the dependency set): the
// self-contained CHECK harness from test_stl.cpp. The golden faithfulness values
// are the PR 201 harness measurements (octet_gen_probe.cpp / octet_cost.csv,
// reproduced to the byte by the strut-lattice-family study): a full 7^3 block of
// 8 mm cells at r = 0.8 mm emits 316000 triangles (8820 struts * 32 + 1688 nodes
// * 20) and a 15,800,084-byte binary STL. Reproducing those exact numbers proves
// the move to production preserved the algorithm operation-for-operation.
//
// LATTICE_TMP_DIR (a writable throwaway dir) is injected by CMake.

#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
#include "topopt/threemf_stream.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

using namespace topopt;

// Weld an unshared-soup mesh by exact quantised coordinate (1e-6 mm) — exactly
// what an STL reader does on re-import, so check_watertight / count_components see
// real topology.
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

static long file_size(const std::string& p) {
  std::ifstream f(p, std::ios::binary | std::ios::ate);
  return f ? static_cast<long>(f.tellg()) : -1;
}

static bool files_identical(const std::string& a, const std::string& b) {
  std::ifstream fa(a, std::ios::binary), fb(b, std::ios::binary);
  if (!fa || !fb) return false;
  std::string sa((std::istreambuf_iterator<char>(fa)), {});
  std::string sb((std::istreambuf_iterator<char>(fb)), {});
  return sa == sb;
}

// The harness's region_200cc: a cube of ~200 cm^3 discretised at cell edge L.
static LatticeRegion region_200cc(double L) {
  const double edge = std::cbrt(200000.0);  // ~58.48 mm
  int n = static_cast<int>(std::llround(edge / L));
  if (n < 1) n = 1;
  LatticeRegion R;
  R.nx = R.ny = R.nz = n;
  R.cell_mm = L;
  R.latticed = nullptr;  // full block (frac = 1)
  return R;
}

int main() {
  // ---- 1. GOLDEN octet reproduction (PR 201) --------------------------------
  {
    LatticeRegion R = region_200cc(8.0);
    CHECK(R.nx == 7 && R.ny == 7 && R.nz == 7, "region_200cc(8) is 7x7x7");
    LatticeRadiusField G;
    G.uniform_mm = 0.10 * 8.0;  // 0.8 mm, the harness's representative r
    G.nseg = 8;

    const std::string stl = tmp("octet_golden.stl");
    StreamingStlWriter w(stl);
    LatticeGenStats st = generate_lattice(LatticeGenTopology::Octet, R, G, w);
    w.finish();

    std::printf("GOLDEN 7^3@8mm: tris=%llu struts=%llu nodes=%llu strut_tris=%llu "
                "node_tris=%llu stl_bytes=%ld\n",
                (unsigned long long)st.triangles, (unsigned long long)st.struts,
                (unsigned long long)st.nodes,
                (unsigned long long)st.strut_triangles,
                (unsigned long long)st.node_triangles, file_size(stl));

    CHECK(st.struts == 8820, "golden strut count 8820");
    CHECK(st.nodes == 1688, "golden node count 1688");
    CHECK(st.triangles == 316000, "golden triangle count 316000");
    CHECK(st.strut_triangles == 8820ull * 32, "golden strut triangles");
    CHECK(st.node_triangles == 1688ull * 20, "golden node triangles");
    CHECK(w.triangle_count() == 316000, "writer counted every triangle");
    CHECK(file_size(stl) == 84 + 50L * 316000, "golden STL byte size 15,800,084");
    CHECK(file_size(stl) == 15800084L, "golden STL byte size literal");
  }

  // ---- 2. DETERMINISM: same inputs twice -> byte-identical file --------------
  {
    LatticeRegion R = region_200cc(12.0);
    LatticeRadiusField G;
    G.uniform_mm = 1.2;
    const std::string a = tmp("det_a.stl"), b = tmp("det_b.stl");
    { StreamingStlWriter w(a); generate_lattice(LatticeGenTopology::Octet, R, G, w); w.finish(); }
    { StreamingStlWriter w(b); generate_lattice(LatticeGenTopology::Octet, R, G, w); w.finish(); }
    CHECK(files_identical(a, b), "determinism: two identical runs are byte-identical");
  }

  // ---- 3. STREAMING == IN-MEMORY: same bytes as the buffered writer ----------
  // Proves the streaming writer's on-disk bytes equal write_stl_file(mesh) fed the
  // same triangle soup, so streaming loses nothing but the memory.
  {
    LatticeRegion R = region_200cc(10.0);
    LatticeRadiusField G;
    G.uniform_mm = 1.0;

    const std::string streamed = tmp("equiv_stream.stl");
    { StreamingStlWriter w(streamed); generate_lattice(LatticeGenTopology::Octet, R, G, w); w.finish(); }

    MeshSink ms;
    generate_lattice(LatticeGenTopology::Octet, R, G, ms);
    const std::string buffered = tmp("equiv_buffer.stl");
    write_stl_file(buffered, ms.mesh, StlFormat::Binary);

    CHECK(files_identical(streamed, buffered),
          "streamed STL is byte-identical to the buffered write of the same soup");
  }

  // ---- 4. EXTERNAL FIELD: the pipeline carries a supplied radius field --------
  // A z-graded radius (NOT the grading LAW — an externally supplied field). The
  // topology (strut/node counts) is unchanged; only diameters swing.
  {
    LatticeRegion R = region_200cc(8.0);
    const double span = R.nz * R.cell_mm;
    LatticeRadiusField Uni;
    Uni.uniform_mm = 0.8;
    LatticeRadiusField Fld;
    Fld.field = [span](Vec3 mid) {
      const double t = std::min(1.0, std::max(0.0, mid.z / span));
      return 0.5 + 0.6 * t;  // 0.5..1.1 mm
    };

    MeshSink mu, mf;
    LatticeGenStats su = generate_lattice(LatticeGenTopology::Octet, R, Uni, mu);
    LatticeGenStats sf = generate_lattice(LatticeGenTopology::Octet, R, Fld, mf);
    CHECK(su.struts == sf.struts && su.nodes == sf.nodes,
          "external field leaves the topology (strut/node counts) unchanged");
    CHECK(su.triangles == sf.triangles, "external field leaves triangle count unchanged");
    CHECK(std::fabs(su.min_strut_diameter_mm - su.max_strut_diameter_mm) < 1e-12,
          "uniform field: constant diameter");
    CHECK(sf.min_strut_diameter_mm < sf.max_strut_diameter_mm - 1e-6,
          "graded field: diameter varies");
    std::printf("FIELD graded diam range: [%.3f, %.3f] mm\n",
                sf.min_strut_diameter_mm, sf.max_strut_diameter_mm);
  }

  // ---- 5. MANIFOLDNESS characteristics (P4), regression-visible --------------
  // The swept-solid union is an interpenetrating soup: each primitive is a closed
  // manifold, welded together they share isolated vertices/junctions. We PIN the
  // welded 2x2x2 block's edge/component counts so a regression moves them.
  {
    LatticeRegion R;
    R.nx = R.ny = R.nz = 2;
    R.cell_mm = 8.0;
    LatticeRadiusField G;
    G.uniform_mm = 0.8;
    MeshSink ms;
    LatticeGenStats st = generate_lattice(LatticeGenTopology::Octet, R, G, ms);
    TriangleMesh welded = weld_soup(ms.mesh);
    WatertightReport wt = check_watertight(welded);
    int comps = count_components(welded);
    std::printf("MANIFOLD 2x2x2: tris=%llu soup_verts=%zu welded_verts=%zu "
                "boundary_edges=%d non_manifold_edges=%d components=%d watertight=%d\n",
                (unsigned long long)st.triangles, ms.mesh.vertices.size(),
                welded.vertices.size(), wt.boundary_edges, wt.non_manifold_edges,
                comps, wt.watertight ? 1 : 0);
    // The union is an INTERPENETRATING SOUP, not a clean 2-manifold: each
    // strut/node is a closed primitive that overlaps its neighbours (the slicer
    // unions them — the property the PR 201 print validated). Welding by
    // coordinate collapses the soup but leaves the primitives as many
    // interpenetrating closed components with non-manifold junctions where cap
    // apexes coincide. These exact counts are PINNED so a regression in the union
    // geometry moves them (P4: manifoldness characteristics regression-visible).
    CHECK(st.triangles == 8940, "2x2x2 triangle count");
    CHECK(welded.vertices.size() == 3249, "2x2x2 welded vertex count");
    CHECK(wt.boundary_edges == 0, "2x2x2 has no boundary edges (closed primitives)");
    CHECK(wt.non_manifold_edges == 2238, "2x2x2 non-manifold junction edges (soup)");
    CHECK(comps == 78, "2x2x2 interpenetrating closed components");
    CHECK(!wt.watertight, "2x2x2 union is a soup, not a single clean 2-manifold");
  }

  // ---- 6. STREAMING 3MF writes a valid, non-empty package --------------------
  {
    LatticeRegion R = region_200cc(12.0);
    LatticeRadiusField G;
    G.uniform_mm = 1.2;
    const std::string mf = tmp("octet.3mf");
    StreamingThreeMfWriter w(mf);
    LatticeGenStats st = generate_lattice(LatticeGenTopology::Octet, R, G, w);
    w.finish();
    CHECK(w.triangle_count() == st.triangles, "3MF writer counted every triangle");
    CHECK(file_size(mf) > 0, "3MF package is non-empty");
    // temp file removed
    CHECK(file_size(mf + ".model.tmp") < 0, "3MF temp model file removed after finish");
    std::printf("3MF 5^3@12mm: tris=%llu bytes=%ld\n",
                (unsigned long long)st.triangles, file_size(mf));
  }

  // ---- 7. Generatable-topology ENUMERATION (task lattice-page-core-hookup) ---
  // lattice_gen_topology_names() is the single source the app bridge reads (H2).
  // The enum-probe tripwire: every enum value the name function can name must be
  // enumerated, so a topology added to the enum + name switch but not the list
  // FAILS here instead of silently vanishing from every picker built on it.
  {
    const std::vector<std::string> names = lattice_gen_topology_names();
    CHECK(!names.empty(), "gen names: non-empty");
    bool has_octet = false;
    for (const std::string& n : names) has_octet = has_octet || n == "octet";
    CHECK(has_octet, "gen names: contains octet");
    // No duplicates.
    bool dup = false;
    for (std::size_t a = 0; a < names.size(); ++a)
      for (std::size_t b = a + 1; b < names.size(); ++b)
        if (names[a] == names[b]) dup = true;
    CHECK(!dup, "gen names: no duplicate names");
    // Probe a generous range of enum values: count how many the name function
    // can name, and require each named one to be IN the list, and the list to
    // contain nothing else. (A new enum case gets a name via the -Wswitch-guarded
    // switch; forgetting the list then fails BOTH counts below.)
    std::size_t named = 0;
    for (int v = 0; v < 32; ++v) {
      std::string n;
      try {
        n = lattice_gen_topology_name(static_cast<LatticeGenTopology>(v));
      } catch (const std::logic_error&) {
        continue;  // not an implemented case
      }
      ++named;
      bool in_list = false;
      for (const std::string& s : names) in_list = in_list || s == n;
      CHECK(in_list, "gen names: every nameable enum value is enumerated");
    }
    CHECK(named == names.size(),
          "gen names: the list has exactly one entry per nameable enum value");
  }

  std::printf("\n%s: %d checks, %d failures\n",
              g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
