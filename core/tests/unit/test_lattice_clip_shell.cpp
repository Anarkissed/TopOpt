// THE STRUT CLIP AND THE EXPORTED SHELL ARE ONE SURFACE (task
// 2026-08-08-strut-clip-matches-shell).
//
// THE DEFECT. The latticed export writes two surfaces into one file: the solid
// SHELL (`variant.v3.mesh` — marching cubes over the physical density) and the
// strut soup, whose centrelines were clipped to a boundary whose base term was
// the distance to the union of solid voxel CUBES. A marching-cubes vertex lies
// on the segment between two voxel CENTRES, so the two surfaces coincide exactly
// on a flat face and the isosurface CHAMFERS the cube union at a convex edge.
// Struts clipped to the cube union therefore ended OUTSIDE the shell — at edges,
// and only at edges, which is exactly what the maintainer saw in his slicer.
//
// THE BAR (task R3): no strut vertex lies outside the shell. Asserted, not
// eyeballed — and asserted against the EXACT signed distance to the shell mesh
// (MeshDistance), never against a re-derivation of the shell.
//
// ★ THESE TESTS ARE ADVERSARIAL BY CONSTRUCTION, in the same shape as bar B3 in
// test_lattice_boundary: every case that requires ZERO protrusion also runs the
// OLD predicate (`set_voxel_base` alone) on the identical fixture and REQUIRES it
// to protrude. A fix that silently stopped clipping, or a fixture with no convex
// edge, would make the new assertion pass vacuously; the paired negative control
// is what makes that impossible.
//
// Self-contained CHECK harness (ARCHITECTURE §4 locks the dependency set).

#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/mesh_distance.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
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

namespace {

// HIS voxel: resolution 128 on M2_verticalStand gives 1.705 mm, so every
// millimetre below is directly comparable with the part he printed.
constexpr double kSpacingMm = 1.705;

struct Fixture {
  VoxelGrid grid;
  std::vector<double> density;
};

// A solid block inside a padded grid: 12 CONVEX EDGES and 8 CONVEX CORNERS and
// nothing else. `notch` removes one corner octant, adding CONCAVE edges — the
// case where the isosurface bulges OUTSIDE the cube union rather than inside it,
// so the fix has to be right in both directions and not merely conservative.
Fixture make_block(int n, int lo, int hi, bool notch) {
  Fixture f;
  f.grid.nx = f.grid.ny = f.grid.nz = n;
  f.grid.spacing = kSpacingMm;
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

// The SHELL the latticed export pushes: run_job.cpp's `export_latticed_variant`
// writes `variant.v3.mesh`, which voxelize.cpp:735+:813 builds as
// keep_largest_component(marching_cubes(grid, density, 0.5)).
TriangleMesh exported_shell(const Fixture& f) {
  return keep_largest_component(marching_cubes(f.grid, f.density, 0.5));
}

struct Protrusion {
  double max_mm = 0.0;
  long long outside = 0;
  long long total = 0;
  Vec3 worst{};
};

// Measures every emitted vertex against `md` (positive = OUTSIDE the shell).
struct ProbeSink : TriangleSink {
  const MeshDistance* md = nullptr;
  Protrusion p;
  void one(const Vec3& v) {
    ++p.total;
    const double out = -md->signed_distance(v);
    if (out > 0.0) {
      ++p.outside;
      if (out > p.max_mm) {
        p.max_mm = out;
        p.worst = v;
      }
    }
  }
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
    one(a);
    one(b);
    one(c);
  }
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

// Generate against `B` and measure every vertex against the shell.
Protrusion run_case(const Fixture& f, const LatticeBoundary& B,
                    const MeshDistance& md, double cell_mm, double radius_mm,
                    LatticeGenStats* out = nullptr) {
  LatticeRegion R = region_for(f.grid, cell_mm, &B);
  LatticeRadiusField G;
  G.uniform_mm = radius_mm;
  LatticeSkinSpec skin;
  skin.mode = LatticeSkinMode::None;
  ProbeSink sink;
  sink.md = &md;
  const LatticeGenStats st =
      generate_lattice(LatticeGenTopology::Octet, R, G, sink, skin);
  if (out) *out = st;
  return sink.p;
}

}  // namespace

int main() {
  // A cell that fits several times across the block, and a radius in the middle
  // of his measured strut range (0.225-0.384 mm) — so the protrusion below is a
  // property of the SURFACE MISMATCH and not of a fat strut.
  const double cell_mm = 4.0 * kSpacingMm;  // 6.82 mm
  const double radius_mm = 0.30;

  // ── 0. MeshDistance itself: the sign convention every assertion below rests
  // on. A utility that assumed a winding rather than measuring it would be
  // silently inverted here — which would make every "0 outside" below vacuous.
  //
  // ★ THIS ASSERTION FLIPPED, ON PURPOSE, AND IT IS THE RECEIPT FOR WHY THE
  // ZEROES BELOW STILL MEAN WHAT THEY MEANT (task
  // 2026-08-09-fix-inward-wound-normals). It used to read `md.inward_wound()`,
  // because marching_cubes emitted inward and `MeshDistance` compensated for it
  // at build time. The no-protrusion invariant was therefore CORRECT BECAUSE OF
  // a compensation for a bug. That bug is now fixed at its source, the
  // compensation no longer fires, and the invariant's zero comes from the
  // geometry itself. Asserting `!inward_wound()` is what makes the difference
  // between those two situations visible instead of inferred: change the winding
  // and leave the compensation (or the reverse) and this line fails, rather than
  // the whole file passing while reporting the opposite of the truth.
  {
    const Fixture f = make_block(20, 6, 13, false);
    const TriangleMesh shell = exported_shell(f);
    const MeshDistance md(shell);
    CHECK(!md.inward_wound(),
          "marching_cubes output is wound OUTWARD, so MeshDistance's winding "
          "compensation must NOT be firing — if this flips, the protrusion "
          "zeroes below are coming from the compensation and not the geometry");
    // Dead centre of the block: 4 solid voxels from each face, and the
    // isosurface sits half a voxel inside the outer cube faces.
    const Vec3 c = f.grid.voxel_center(9, 9, 9);
    CHECK(md.signed_distance(c) > 2.0 * kSpacingMm,
          "the block's centre must be well INSIDE the shell (positive)");
    const Vec3 far{-10.0, -10.0, -10.0};
    CHECK(md.signed_distance(far) < 0.0,
          "a point far outside the block must be OUTSIDE the shell (negative)");
    // On the shell itself: a marching-cubes vertex is on the surface.
    CHECK(std::fabs(md.signed_distance(shell.vertices[0])) < 1e-9,
          "a shell vertex must be at distance 0 from the shell");
  }

  // ── 0b. ★ THE ACCELERATOR MUST AGREE WITH BRUTE FORCE, EVERYWHERE.
  //
  // THIS IS THE TEST THAT CAUGHT THE REAL BUG, and it is here because the bug it
  // caught was invisible to every other check in this file. `MeshDistance` walks
  // expanding Chebyshev shells of its uniform grid and stops when the best hit
  // beats a coverage bound. The first version tested that bound at the TOP of the
  // iteration — using the radius-s box while holding only shells 0..s-1 — which
  // overstates coverage by one shell and can return a distance up to one
  // accelerator cell TOO LARGE.
  //
  // TOO LARGE IS THE DANGEROUS DIRECTION. It makes the clip keep a span it has
  // not proved, and it breaks the 1-LIPSCHITZ property the entire certified-clip
  // argument rests on. On the block fixture below the error never surfaced;
  // ctest `lattice_void_exterior` caught it on a real l-bracket design, as struts
  // emitted 0.839 mm outside the shell they had just been clipped against.
  //
  // Brute force over every triangle has no such bound to get wrong, so it is the
  // oracle. The mesh is small enough that the full scan is cheap.
  {
    const Fixture f = make_block(16, 5, 10, true);
    const TriangleMesh shell = exported_shell(f);
    const MeshDistance md(shell);

    auto brute_unsigned = [&shell](const Vec3& p) {
      double best = 1e300;
      for (const auto& t : shell.triangles) {
        // Closest point on the triangle, by dense barycentric sampling plus the
        // three edges — deliberately DUMB, so it shares no code with the thing it
        // is checking. The sampling is fine enough that the max error is far
        // below the tolerance asserted at the call site.
        const Vec3& a = shell.vertices[static_cast<std::size_t>(t[0])];
        const Vec3& b = shell.vertices[static_cast<std::size_t>(t[1])];
        const Vec3& c = shell.vertices[static_cast<std::size_t>(t[2])];
        for (int i = 0; i <= 24; ++i)
          for (int j = 0; i + j <= 24; ++j) {
            const double u = i / 24.0, v = j / 24.0, w = 1.0 - u - v;
            const Vec3 q{a.x * w + b.x * u + c.x * v, a.y * w + b.y * u + c.y * v,
                         a.z * w + b.z * u + c.z * v};
            const double dx = p.x - q.x, dy = p.y - q.y, dz = p.z - q.z;
            best = std::min(best, dx * dx + dy * dy + dz * dz);
          }
      }
      return std::sqrt(best);
    };

    // A deterministic lattice of probes over and around the block, at an offset
    // that avoids landing exactly on the surface (where the sign is ill-defined
    // and a tie is legitimate).
    double worst_abs = 0.0, worst_lip = 0.0;
    int checked = 0;
    const double h = kSpacingMm;
    Vec3 prev{0, 0, 0};
    double prev_sd = 0.0;
    for (int k = 0; k < 9; ++k)
      for (int j = 0; j < 9; ++j)
        for (int i = 0; i < 9; ++i) {
          const Vec3 p{(3.0 + 1.37 * i) * h, (3.0 + 1.37 * j) * h,
                       (3.0 + 1.37 * k) * h};
          const double sd = md.signed_distance(p);
          worst_abs = std::max(worst_abs, std::fabs(std::fabs(sd) -
                                                    brute_unsigned(p)));
          if (checked > 0) {
            const double dx = p.x - prev.x, dy = p.y - prev.y, dz = p.z - prev.z;
            const double step = std::sqrt(dx * dx + dy * dy + dz * dz);
            worst_lip = std::max(worst_lip, std::fabs(sd - prev_sd) - step);
          }
          prev = p;
          prev_sd = sd;
          ++checked;
        }
    std::printf(
        "  [oracle]  %d probes: max |accelerated| - |brute force| = %.9f mm; "
        "worst Lipschitz excess = %.9f mm\n",
        checked, worst_abs, worst_lip);
    CHECK(worst_abs < 5e-3,
          "the accelerated distance must equal the brute-force distance — an "
          "accelerator that returns TOO LARGE a distance makes the clip keep "
          "spans it has not proved");
    CHECK(worst_lip <= 1e-9,
          "the signed distance must be 1-Lipschitz — the certified clip's whole "
          "argument rests on it");
  }

  // ── 1. THE DEFECT, on a convex-edge fixture. The OLD predicate (voxel-cube
  // base) must put strut vertices OUTSIDE the exported shell. This is the
  // negative control the rest of the file leans on: it is what made the fixture
  // able to fail at all.
  //
  // MEASURED before the fix (evidence/2026-08-08-strut-clip-matches-shell/
  // s1_protrusion.csv): 2880 of 496092 vertices outside, worst 0.178444 mm.
  {
    const Fixture f = make_block(40, 8, 31, false);
    const TriangleMesh shell = exported_shell(f);
    const MeshDistance md(shell);

    LatticeBoundary cube;
    cube.set_voxel_base(&f.grid, &f.density, 0.5, 2.0 * cell_mm);
    const Protrusion old_p = run_case(f, cube, md, cell_mm, radius_mm);
    std::printf(
        "  [control] voxel-cube clip: %lld of %lld vertices outside the shell, "
        "worst %.6f mm at (%.3f, %.3f, %.3f)\n",
        old_p.outside, old_p.total, old_p.max_mm, old_p.worst.x, old_p.worst.y,
        old_p.worst.z);
    CHECK(old_p.outside > 0 && old_p.max_mm > 0.05,
          "NEGATIVE CONTROL: clipping to the voxel-cube union must protrude "
          "past the exported shell on a convex-edge part — if this stops "
          "failing the fixture no longer exercises the defect");

    // ── 2. THE BAR. Clipped against the shell the file carries: ZERO.
    LatticeBoundary shellB;
    shellB.set_voxel_base(&f.grid, &f.density, 0.5, 2.0 * cell_mm);
    shellB.set_shell_base(&shell);
    CHECK(shellB.has_shell_base(), "set_shell_base must be recorded");
    LatticeGenStats st{};
    const Protrusion p = run_case(f, shellB, md, cell_mm, radius_mm, &st);
    std::printf(
        "  [fixed]   shell clip:      %lld of %lld vertices outside, worst "
        "%.6f mm; struts %llu, clipped %llu, dropped %llu\n",
        p.outside, p.total, p.max_mm, (unsigned long long)st.struts,
        (unsigned long long)st.clipped_struts,
        (unsigned long long)st.dropped_struts);
    CHECK(p.outside == 0,
          "NO strut vertex may lie outside the exported shell");
    CHECK(p.max_mm <= LatticeBoundary::kClipTolMm,
          "max protrusion must be zero to the clip's own resolution");
    // The fixture must still produce a real lattice — otherwise "0 outside"
    // would be satisfied by emitting nothing.
    CHECK(st.struts > 100 && p.total > 10000,
          "the fixed case must still emit a substantial lattice");
  }

  // ── 3. CONCAVE EDGES TOO. On the notched block the isosurface bulges OUTSIDE
  // the cube union along the reentrant corner, so a fix that merely eroded the
  // cube union would be conservative there and lose lattice for no reason, while
  // still having to hold the bar. Both are checked.
  {
    const Fixture f = make_block(40, 8, 31, true);
    const TriangleMesh shell = exported_shell(f);
    const MeshDistance md(shell);

    LatticeBoundary cube;
    cube.set_voxel_base(&f.grid, &f.density, 0.5, 2.0 * cell_mm);
    LatticeGenStats st_old{};
    const Protrusion old_p =
        run_case(f, cube, md, cell_mm, radius_mm, &st_old);
    CHECK(old_p.outside > 0,
          "NEGATIVE CONTROL (notched): the voxel-cube clip must protrude here "
          "too");

    LatticeBoundary shellB;
    shellB.set_voxel_base(&f.grid, &f.density, 0.5, 2.0 * cell_mm);
    shellB.set_shell_base(&shell);
    LatticeGenStats st{};
    const Protrusion p = run_case(f, shellB, md, cell_mm, radius_mm, &st);
    std::printf(
        "  [notched] shell clip:      %lld of %lld vertices outside, worst "
        "%.6f mm; struts %llu (control %llu)\n",
        p.outside, p.total, p.max_mm, (unsigned long long)st.struts,
        (unsigned long long)st_old.struts);
    CHECK(p.outside == 0,
          "NO strut vertex may lie outside the exported shell (notched)");
    // The concave direction: clipping to the SHELL must not lose lattice
    // relative to the cube union, because at a reentrant corner the shell is
    // OUTSIDE the cube union. A blanket erosion would fail this.
    CHECK(st.struts >= st_old.struts,
          "clipping to the shell must not lose struts relative to the "
          "voxel-cube union on a part with concave edges");
  }

  // ── 4. THE SHELL BASE SUPERSEDES THE VOXEL BASE, and the order of the two
  // calls does not matter. If it did, the surface a run clipped against would
  // depend on construction order — a silent, invisible divergence of exactly the
  // kind this task exists to remove.
  {
    const Fixture f = make_block(24, 6, 17, false);
    const TriangleMesh shell = exported_shell(f);
    LatticeBoundary a, b;
    a.set_voxel_base(&f.grid, &f.density, 0.5, 2.0 * cell_mm);
    a.set_shell_base(&shell);
    b.set_shell_base(&shell);
    b.set_voxel_base(&f.grid, &f.density, 0.5, 2.0 * cell_mm);
    bool same = true;
    for (int t = 0; t < 200; ++t) {
      const double u = static_cast<double>(t) / 199.0;
      const Vec3 p{f.grid.origin.x + u * f.grid.nx * f.grid.spacing,
                   f.grid.origin.y + (0.31 + 0.4 * u) * f.grid.ny * f.grid.spacing,
                   f.grid.origin.z + (0.77 - 0.5 * u) * f.grid.nz * f.grid.spacing};
      if (a.signed_distance(p) != b.signed_distance(p)) same = false;
    }
    CHECK(same,
          "set_shell_base must supersede set_voxel_base regardless of the order "
          "the two are called in");
  }

  // ── 5. A BOUNDARY WITH NO SHELL IS UNTOUCHED. Every existing caller that
  // never supplies a mesh must evaluate bit-for-bit what it did before, which is
  // what keeps a no-lattice run byte-identical (bar R1).
  {
    const Fixture f = make_block(24, 6, 17, false);
    LatticeBoundary v;
    v.set_voxel_base(&f.grid, &f.density, 0.5, 2.0 * cell_mm);
    CHECK(!v.has_shell_base(), "a voxel-base boundary must report no shell");
    CHECK(v.has_base(), "a voxel-base boundary still has a base");
    // The exact voxel-cube answer at a face centre: the cube face is half a
    // voxel outside the centre it bounds.
    const Vec3 c = f.grid.voxel_center(6, 11, 11);
    CHECK(std::fabs(v.signed_distance(c) - 0.5 * kSpacingMm) < 1e-12,
          "the voxel-cube base must be unchanged when no shell is set");
  }

  // ── 6. AN EMPTY SHELL IS A PROGRAMMING ERROR, not a silent no-op — a caller
  // that means "no shell base" must not call set_shell_base at all, or the run
  // would clip against nothing and emit the whole block.
  {
    bool threw = false;
    LatticeBoundary B;
    TriangleMesh empty;
    try {
      B.set_shell_base(&empty);
    } catch (const std::exception&) {
      threw = true;
    }
    CHECK(threw, "set_shell_base(empty) must throw");
    threw = false;
    try {
      B.set_shell_base(nullptr);
    } catch (const std::exception&) {
      threw = true;
    }
    CHECK(threw, "set_shell_base(nullptr) must throw");
  }

  std::printf("test_lattice_clip_shell: %d checks, %d failures\n", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
