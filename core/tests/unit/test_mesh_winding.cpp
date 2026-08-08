// EVERY MESH CORE SYNTHESIZES IS WOUND OUTWARD (task
// 2026-08-09-fix-inward-wound-normals).
//
// THE DEFECT. `mesh.hpp` documents `signed_volume` as returning "the positive
// enclosed volume" "for the outward-facing counter-clockwise winding STL
// specifies". Every mesh core BUILT violated that: `marching_cubes` and the
// lattice generator's primitives emitted triangles whose (b-a)x(c-a) normal
// points INTO the solid, so `write_stl_file` — which derives each facet normal
// from the winding (stl.cpp, facet_normal) — wrote inverted normals into every
// exported STL and 3MF. Measured on shipped artifacts before the fix:
// variant_068.stl enclosed -442,684 mm^3.
//
// It stayed invisible because every consumer either takes `std::fabs` (the
// volume bookkeeping) or MEASURES the winding and compensates
// (`MeshDistance`, `surface_operator`'s vertex normals) — and because slicers
// auto-repair inverted normals, so prints came out.
//
// ★ WHY THIS FILE COVERS THE LATTICE GENERATOR TOO, and why that is not scope
// creep. The latticed export writes the marching-cubes SHELL and the generator's
// strut soup into ONE file. Fixing only marching_cubes would leave that file
// MIXED — an outward shell around inward struts — which is strictly worse than
// being uniformly wrong. The measurement that establishes both were inward is
// evidence/2026-08-09-fix-inward-wound-normals/s1_producer_map.txt.
//
// ★ AND WHY THE IMPORTERS ARE HERE AS A NEGATIVE CONTROL. A "fix" that flipped
// everything indiscriminately would invert imported STEP/STL geometry, which is
// already outward. The import cases below fail on exactly that mistake.
//
// Self-contained CHECK harness (ARCHITECTURE §4 locks the dependency set).
// MESH_TMP_DIR (a writable throwaway dir) is injected by CMake.

#include "topopt/clearance.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

static std::string tmp(const std::string& name) {
  return std::string(MESH_TMP_DIR) + "/" + name;
}

namespace {

// A 4x4x4-voxel solid block of 1 mm voxels inside a padded 10^3 grid. Its
// marching-cubes body spans 3.0..7.0 with the 12 edges and 8 corners chamfered,
// which is 58.666667 mm^3 — a number this file pins, so a "flip" that also
// corrupted the geometry could not pass by merely changing a sign.
struct Block {
  VoxelGrid grid;
  std::vector<double> density;
};

Block make_block() {
  Block b;
  b.grid.nx = b.grid.ny = b.grid.nz = 10;
  b.grid.spacing = 1.0;
  b.grid.origin = Vec3{0, 0, 0};
  b.grid.tags.assign(1000, VoxelTag::Empty);
  b.density.assign(1000, 0.0);
  for (int k = 3; k <= 6; ++k)
    for (int j = 3; j <= 6; ++j)
      for (int i = 3; i <= 6; ++i) {
        b.grid.tags[b.grid.index(i, j, k)] = VoxelTag::Interior;
        b.density[b.grid.index(i, j, k)] = 1.0;
      }
  return b;
}

bool close_to(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

// An axis-aligned cube written as an OUTWARD-wound STL soup — the negative
// control's input. Built by hand so it does not inherit any core convention.
TriangleMesh outward_cube(double s) {
  TriangleMesh m;
  const Vec3 v[8] = {{0, 0, 0}, {s, 0, 0}, {s, s, 0}, {0, s, 0},
                     {0, 0, s}, {s, 0, s}, {s, s, s}, {0, s, s}};
  for (const Vec3& p : v) m.vertices.push_back(p);
  const int f[12][3] = {{0, 3, 2}, {0, 2, 1},  // -z
                        {4, 5, 6}, {4, 6, 7},  // +z
                        {0, 1, 5}, {0, 5, 4},  // -y
                        {2, 3, 7}, {2, 7, 6},  // +y
                        {0, 4, 7}, {0, 7, 3},  // -x
                        {1, 2, 6}, {1, 6, 5}}; // +x
  for (const auto& t : f) m.triangles.push_back({t[0], t[1], t[2]});
  return m;
}

}  // namespace

int main() {
  const Block b = make_block();
  const double kBlockVolume = 58.6666666666666667;

  // ── 1. marching_cubes, the primary synthesizer.
  {
    const TriangleMesh m = marching_cubes(b.grid, b.density, 0.5);
    const double v = signed_volume(m);
    std::printf("  marching_cubes                       signed_volume %+.6f\n", v);
    CHECK(v > 0.0,
          "marching_cubes must emit OUTWARD-wound triangles — signed_volume is "
          "the positive enclosed volume for the winding STL specifies "
          "(mesh.hpp), and every exported STL derives its facet normals from it");
    CHECK(close_to(std::fabs(v), kBlockVolume, 1e-9),
          "and the geometry must be UNCHANGED: |signed_volume| must still be the "
          "block's 58.666667 mm^3, so a sign fix cannot hide a geometry break");
    // The largest-component cleanup and the resample must not undo it.
    CHECK(signed_volume(keep_largest_component(m)) > 0.0,
          "keep_largest_component must preserve the outward winding");
    const TriangleMesh r = marching_cubes_resampled(
        b.grid.nx, b.grid.ny, b.grid.nz, b.grid.spacing, b.grid.origin,
        b.density, 0.5, 2, ResampleInterp::Tricubic);
    CHECK(signed_volume(r) > 0.0,
          "marching_cubes_resampled must be outward too — it is what the SOLID "
          "export writes at smooth_factor > 1");
  }

  // ── 2. THE WRITTEN FILE, which is the thing the slicer actually reads.
  // A round trip through the binary STL writer and reader: the facet normals it
  // stores are derived from the winding, so this is the end-to-end property.
  {
    const TriangleMesh m = marching_cubes(b.grid, b.density, 0.5);
    const std::string path = tmp("winding_mc.stl");
    write_stl_file(path, m);
    const StlMesh back = read_stl_file(path);
    const double v = signed_volume(back.mesh);
    std::printf("  marching_cubes -> STL -> re-read      signed_volume %+.6f\n", v);
    CHECK(v > 0.0,
          "a written-and-re-read STL of a core-built mesh must enclose a "
          "POSITIVE volume — this is the property a slicer sees");
    CHECK(close_to(std::fabs(v), kBlockVolume, 1e-3),
          "and the round trip must not move the geometry");
  }

  // ── 3. THE LATTICE GENERATOR's own primitives. One cell with no boundary, so
  // every strut and node is emitted whole; the soup is interpenetrating, so its
  // signed volume is the SUM of the individual closed primitives' volumes —
  // well defined, and positive exactly when every primitive is outward.
  {
    LatticeRegion R;
    R.origin = Vec3{0, 0, 0};
    R.nx = R.ny = R.nz = 1;
    R.cell_mm = 10.0;
    R.boundary = nullptr;
    LatticeRadiusField G;
    G.uniform_mm = 1.0;
    G.nseg = 8;
    LatticeSkinSpec skin;
    skin.mode = LatticeSkinMode::None;
    MeshSink sink;
    const LatticeGenStats st =
        generate_lattice(LatticeGenTopology::Octet, R, G, sink, skin);
    const double v = signed_volume(sink.mesh);
    std::printf("  generate_lattice (soup, %llu struts) signed_volume %+.6f\n",
                (unsigned long long)st.struts, v);
    CHECK(v > 0.0,
          "the lattice generator's struts and nodes must be OUTWARD too — the "
          "latticed export writes them into the SAME file as the shell, and a "
          "file that is outward in one body and inward in another is worse than "
          "one that is uniformly wrong");
    // ★ THE ONE MAGNITUDE THAT LEGITIMATELY MOVED, and why. Before the fix this
    // soup measured -684.4939, which is NOT a volume: it is
    // -(36 x 20.000 strut) + (14 x 2.536 node), a MIXED-SIGN sum. The struts
    // were inward while the node balls were already outward, so the lattice soup
    // was never uniformly wound in the first place. With every primitive outward
    // the sum is the honest total, 755.5061 mm^3 — and it now agrees exactly
    // with the generator's own analytic accounting, which is the next check.
    CHECK(close_to(std::fabs(v), 755.506110, 1e-3),
          "the emitted lattice primitives must total 755.5061 mm^3 on this "
          "fixture");
    // The generator's OWN analytic accounting must agree with the geometry it
    // actually emitted — a flip that changed only one of the two would show up
    // here as a mismatch rather than as a passing sign test.
    CHECK(close_to(st.interior_volume_mm3, std::fabs(v), 1e-3),
          "LatticeGenStats::interior_volume_mm3 must equal the volume the "
          "emitted triangles actually enclose");
  }

  // ── 3b. THE RIM/COLLAR PASS, which has its own triangle emission rather than
  // going through emit_strut. It needs a PLANE face paired with a collar BORE,
  // so the boundary is an analytic box plus a bolt keep-out — the one
  // configuration that reaches emit_rim_torus. Without this case the torus and
  // its end caps could stay inward while everything around them was fixed.
  {
    LatticeBoundary B;
    B.add_box(Vec3{0, 0, 0}, Vec3{20, 20, 20});
    ClearanceGeometry bore;
    bore.valid = true;
    bore.kind = ClearanceKind::Bolt;
    bore.axis_point = Vec3{10, 10, 0};
    bore.axis_dir = Vec3{0, 0, 1};
    bore.radius = 3.0;
    bore.t_lo = -1.0;
    bore.t_hi = 21.0;
    B.add_keep_out(bore, /*collar=*/true);

    LatticeRegion R;
    R.origin = Vec3{0, 0, 0};
    R.nx = R.ny = R.nz = 2;
    R.cell_mm = 10.0;
    R.boundary = &B;
    LatticeRadiusField G;
    G.uniform_mm = 0.8;
    G.nseg = 8;
    LatticeSkinSpec skin;
    skin.mode = LatticeSkinMode::Rim;
    skin.min_radius_mm = 0.5;
    MeshSink sink;
    const LatticeGenStats st =
        generate_lattice(LatticeGenTopology::Octet, R, G, sink, skin);
    std::printf("  collar run: rim_triangles %llu, soup signed_volume %+.6f\n",
                (unsigned long long)st.rim_triangles, signed_volume(sink.mesh));
    CHECK(st.rim_triangles > 0,
          "the collar fixture must actually REACH emit_rim_torus — otherwise "
          "the winding assertion below passes vacuously");
    CHECK(signed_volume(sink.mesh) > 0.0,
          "the rim/collar pass must emit OUTWARD-wound triangles too");
    // ★ THE CROSS-CHECK, not just the sign. A positive TOTAL can hide one
    // inward family inside two outward ones — which is exactly how the node
    // balls' correct winding got broken and then caught, in this very file.
    //
    // The rim is checked with a BAND rather than to the last bit, and the reason
    // is stated so the band is not mistaken for slack: `rim_volume_mm3` is the
    // ANALYTIC torus volume while the emission is a faceted tube inscribed in
    // it, so the emitted geometry is legitimately ~2% under (measured: 10.161 of
    // 495.697). An INWARD rim family would not be 2% under — it would subtract
    // its whole volume twice, which is 200% out. The second clause is the one
    // that catches that, and it cannot be satisfied by any discretization error.
    const double analytic =
        st.interior_volume_mm3 + st.rim_volume_mm3 + st.skin_volume_mm3;
    const double emitted = signed_volume(sink.mesh);
    CHECK(emitted > 0.97 * analytic && emitted <= analytic + 1e-6,
          "the collar run's emitted volume must match interior + rim + skin from "
          "LatticeGenStats to within the tube's facet inscription (~2%)");
    CHECK(emitted > st.interior_volume_mm3 + 0.9 * st.rim_volume_mm3,
          "the rim tori must ADD volume, not subtract it — an inward-wound rim "
          "family would land near interior MINUS rim and fail here");
  }

  // ── 4. ★ NEGATIVE CONTROL: THE IMPORTERS ARE ALREADY RIGHT AND MUST NOT MOVE.
  // A hand-built OUTWARD cube, written and read back, must stay positive. A fix
  // that flipped winding indiscriminately — at the writer, or globally — inverts
  // this and fails here.
  {
    const TriangleMesh cube = outward_cube(10.0);
    CHECK(close_to(signed_volume(cube), 1000.0, 1e-9),
          "the control cube is outward by construction (1000 mm^3)");
    const std::string path = tmp("winding_cube.stl");
    write_stl_file(path, cube);
    const StlMesh back = read_stl_file(path);
    std::printf("  hand-built outward cube -> STL -> re-read  signed_volume %+.6f\n",
                signed_volume(back.mesh));
    CHECK(close_to(signed_volume(back.mesh), 1000.0, 1e-3),
          "★ the STL writer must not flip anything: an already-outward mesh "
          "round-trips to +1000 mm^3. Fixing the winding at the WRITER instead "
          "of at the synthesizer breaks exactly this.");
  }

  std::printf("test_mesh_winding: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
