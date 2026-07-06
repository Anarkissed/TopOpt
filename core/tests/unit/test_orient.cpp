// Unit tests for orientation candidate generation + the support-volume proxy
// metric (ROADMAP M4.3).
//
// No third-party test framework (ARCHITECTURE §4), so this uses the same
// self-contained CHECK harness as the other tests and drives the public API only
// (topopt/orient.hpp). Meshes and voxel grids are built in code, so the test is
// pure C++/std and runs in every build configuration (no OCCT, no Eigen).

#include "topopt/mesh.hpp"
#include "topopt/orient.hpp"
#include "topopt/voxel.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::flat_face_normals;
using topopt::max_interlayer_tension;
using topopt::orientation_candidates;
using topopt::OrientationScore;
using topopt::score_orientations;
using topopt::support_overhang_voxels;
using topopt::TriangleMesh;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

double dot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
double length(const Vec3& a) { return std::sqrt(dot(a, a)); }

// Is a direction within tol (as a dot-product threshold) of some candidate?
bool contains_dir(const std::vector<Vec3>& v, const Vec3& d, double tol = 1e-6) {
  const double dl = length(d);
  for (const Vec3& e : v)
    if (dot(e, Vec3{d.x / dl, d.y / dl, d.z / dl}) > 1.0 - tol) return true;
  return false;
}

// Add one axis-aligned rectangular face (two triangles) with outward normal
// pointing away from the box centre. `a`,`b` are the two in-plane extents.
void add_quad(TriangleMesh& m, const Vec3& p0, const Vec3& ea, const Vec3& eb) {
  const int base = static_cast<int>(m.vertices.size());
  m.vertices.push_back(p0);
  m.vertices.push_back(Vec3{p0.x + ea.x, p0.y + ea.y, p0.z + ea.z});
  m.vertices.push_back(
      Vec3{p0.x + ea.x + eb.x, p0.y + ea.y + eb.y, p0.z + ea.z + eb.z});
  m.vertices.push_back(Vec3{p0.x + eb.x, p0.y + eb.y, p0.z + eb.z});
  m.triangles.push_back({base + 0, base + 1, base + 2});
  m.triangles.push_back({base + 0, base + 2, base + 3});
}

// A closed axis-aligned box [0,lx]x[0,ly]x[0,lz] with outward-facing winding.
// (Winding is irrelevant to flat_face_normals — it groups both +/-n together via
// area — but the six faces give the six axis normals.)
TriangleMesh make_box(double lx, double ly, double lz) {
  TriangleMesh m;
  // Each face's two in-plane edge vectors are ordered so cross(ea, eb) is the
  // outward normal, giving the six distinct axis normals.
  add_quad(m, Vec3{0, 0, 0}, Vec3{0, ly, 0}, Vec3{lx, 0, 0});   // z = 0  (-z)
  add_quad(m, Vec3{0, 0, lz}, Vec3{lx, 0, 0}, Vec3{0, ly, 0});  // z = lz (+z)
  add_quad(m, Vec3{0, 0, 0}, Vec3{lx, 0, 0}, Vec3{0, 0, lz});   // y = 0  (-y)
  add_quad(m, Vec3{0, ly, 0}, Vec3{0, 0, lz}, Vec3{lx, 0, 0});  // y = ly (+y)
  add_quad(m, Vec3{0, 0, 0}, Vec3{0, 0, lz}, Vec3{0, ly, 0});   // x = 0  (-x)
  add_quad(m, Vec3{lx, 0, 0}, Vec3{0, ly, 0}, Vec3{0, 0, lz});  // x = lx (+x)
  return m;
}

VoxelGrid empty_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Empty);
  return g;
}

VoxelGrid solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g = empty_grid(nx, ny, nz, h);
  g.tags.assign(g.tags.size(), VoxelTag::Interior);
  return g;
}

// ------------------------------------------------------------------------
// flat_face_normals
// ------------------------------------------------------------------------
void test_flat_face_normals() {
  // A box has exactly six significant flat faces: the six axis normals.
  TriangleMesh box = make_box(2.0, 2.0, 2.0);
  std::vector<Vec3> fn = flat_face_normals(box);
  CHECK(fn.size() == 6, "box has 6 flat faces");
  const Vec3 axes[6] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
                        {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
  for (const Vec3& a : axes)
    CHECK(contains_dir(fn, a), "box flat-face normal set contains each axis");
  for (const Vec3& n : fn)
    CHECK(std::fabs(length(n) - 1.0) < 1e-9, "flat-face normal is unit");

  // A non-cubic box still has 6 faces (unequal areas, all above 5% of total).
  CHECK(flat_face_normals(make_box(1.0, 3.0, 5.0)).size() == 6,
        "non-cubic box has 6 flat faces");

  // A large slanted face with normal (2,0,1)/sqrt(5) is extracted; a tiny +y
  // sliver whose area is below area_fraction of the total is NOT reported.
  {
    TriangleMesh m;
    // Big slanted quad in the plane 2x + z = const: in-plane axes (0,1,0) and
    // (1,0,-2) are both perpendicular to (2,0,1); a 10x10-scaled quad => area 500.
    add_quad(m, Vec3{0, 0, 0}, Vec3{0, 10, 0}, Vec3{10, 0, -20});
    // Tiny axis-aligned +y triangle, area 0.5 (far below 5% of ~500).
    const int base = static_cast<int>(m.vertices.size());
    m.vertices.push_back(Vec3{0, 100, 0});
    m.vertices.push_back(Vec3{1, 100, 0});
    m.vertices.push_back(Vec3{0, 100, 1});
    m.triangles.push_back({base + 0, base + 1, base + 2});

    std::vector<Vec3> s = flat_face_normals(m);
    CHECK(s.size() == 1, "only the large slanted face clears the area threshold");
    const Vec3 slant{2.0 / std::sqrt(5.0), 0.0, 1.0 / std::sqrt(5.0)};
    CHECK(s.size() == 1 &&
              (contains_dir(s, slant) ||
               contains_dir(s, Vec3{-slant.x, -slant.y, -slant.z})),
          "slanted-face normal recovered as (2,0,1)/sqrt(5)");
    // With a small enough area_fraction the tiny sliver is also reported.
    CHECK(flat_face_normals(m, 1e-6).size() == 2,
          "lowering area_fraction reports the sliver too");
  }

  // Argument validation.
  bool threw = false;
  try {
    flat_face_normals(TriangleMesh{});
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "empty mesh throws");
  threw = false;
  try {
    flat_face_normals(box, 0.0);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "area_fraction 0 throws");
  threw = false;
  try {
    flat_face_normals(box, 1.5);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "area_fraction > 1 throws");
}

// ------------------------------------------------------------------------
// orientation_candidates
// ------------------------------------------------------------------------
void test_orientation_candidates() {
  // Axis-aligned box: every flat-face normal is already a lattice direction, so
  // the candidate set is exactly the 26 coarse-sphere directions.
  TriangleMesh box = make_box(2.0, 2.0, 2.0);
  std::vector<Vec3> c = orientation_candidates(box);
  CHECK(c.size() == 26, "box candidate set is exactly the 26 sphere directions");

  // The 6 axis-aligned directions are present.
  const Vec3 axes[6] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
                        {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
  for (const Vec3& a : axes)
    CHECK(contains_dir(c, a), "candidate set contains each axis direction");

  // All candidates are unit and pairwise distinct (> ~1.8 deg apart).
  bool all_unit = true, all_distinct = true;
  for (std::size_t p = 0; p < c.size(); ++p) {
    if (std::fabs(length(c[p]) - 1.0) > 1e-9) all_unit = false;
    for (std::size_t q = p + 1; q < c.size(); ++q)
      if (dot(c[p], c[q]) > 0.9995) all_distinct = false;
  }
  CHECK(all_unit, "all candidates are unit vectors");
  CHECK(all_distinct, "candidates are pairwise distinct (deduplicated)");

  // The 26 sphere directions partition into 6 face + 12 edge + 8 corner by the
  // number of nonzero components — a structural check on the coarse sample.
  int face = 0, edge = 0, corner = 0;
  for (const Vec3& d : c) {
    int nz = (std::fabs(d.x) > 1e-9) + (std::fabs(d.y) > 1e-9) +
             (std::fabs(d.z) > 1e-9);
    if (nz == 1) ++face;
    else if (nz == 2) ++edge;
    else if (nz == 3) ++corner;
  }
  CHECK(face == 6 && edge == 12 && corner == 8,
        "coarse sphere sample is 6 face + 12 edge + 8 corner directions");

  // A slanted flat face (not aligned with any lattice direction) adds itself and
  // its opposite: 26 + 2 = 28 candidates.
  {
    TriangleMesh m;
    add_quad(m, Vec3{0, 0, 0}, Vec3{0, 10, 0}, Vec3{10, 0, -20});  // n ~ (2,0,1)
    std::vector<Vec3> cc = orientation_candidates(m);
    CHECK(cc.size() == 28, "a slanted flat face adds its two orientations");
    const Vec3 slant{2.0 / std::sqrt(5.0), 0.0, 1.0 / std::sqrt(5.0)};
    CHECK(contains_dir(cc, slant), "candidate set contains the slant normal");
    CHECK(contains_dir(cc, Vec3{-slant.x, -slant.y, -slant.z}),
          "candidate set contains the opposite of the slant normal");
  }

  // Empty mesh (no faces to align to) throws.
  bool threw = false;
  try {
    orientation_candidates(TriangleMesh{});
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "orientation_candidates on an empty mesh throws");
}

// ------------------------------------------------------------------------
// support_overhang_voxels
// ------------------------------------------------------------------------
void test_support_overhang() {
  // A solid box needs no support in any axis orientation: the base rests on the
  // plate and every other voxel is supported by the one directly beneath it.
  {
    VoxelGrid g = solid_grid(3, 3, 3, 1.0);
    const Vec3 dirs[6] = {{0, 0, 1}, {0, 0, -1}, {1, 0, 0},
                          {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}};
    for (const Vec3& d : dirs)
      CHECK(support_overhang_voxels(g, d) == 0,
            "solid box has zero overhang voxels for every axis build direction");
  }

  // Post + horizontal arm: a vertical post at i=0 (k=0..3) and an arm at k=3
  // (i=0..4), in a single j-plane. Hand computed below.
  //   Build +z: base is the post foot (k=0). The arm voxel i=1 is supported by
  //     the post at exactly 45 deg; i=2,3,4 hang free => 3 overhang voxels.
  //   Build -z: the whole k=3 arm slab is the base; the post hangs beneath it,
  //     each voxel supported from above => 0 overhang voxels.
  //   Build +x: the whole i=0 post is the base; the arm lies along the build
  //     direction, each voxel supported by its neighbour toward the plate => 0.
  {
    VoxelGrid g = empty_grid(5, 1, 4, 1.0);
    for (int k = 0; k <= 3; ++k) g.set_tag(0, 0, k, VoxelTag::Interior);  // post
    for (int i = 0; i <= 4; ++i) g.set_tag(i, 0, 3, VoxelTag::Interior);  // arm

    CHECK(support_overhang_voxels(g, Vec3{0, 0, 1}) == 3,
          "post+arm has 3 overhang voxels built +z (45-deg reach supports i=1)");
    CHECK(support_overhang_voxels(g, Vec3{0, 0, -1}) == 0,
          "post+arm has 0 overhang voxels built -z (arm is the base)");
    CHECK(support_overhang_voxels(g, Vec3{1, 0, 0}) == 0,
          "post+arm has 0 overhang voxels built +x (arm along build dir)");

    // A non-unit build direction is normalized: same result as its unit form.
    CHECK(support_overhang_voxels(g, Vec3{0, 0, 5}) == 3,
          "non-unit build_dir is normalized");
  }

  // A horizontal shelf floating above a single central pillar: the shelf voxels
  // beyond the 45-deg reach of the pillar are overhangs. 5-wide shelf at k=2 over
  // a pillar at (2,2,0..1): built +z the base is the pillar foot; the shelf
  // corners/edges past 45 deg from the pillar need support.
  {
    VoxelGrid g = empty_grid(5, 5, 3, 1.0);
    g.set_tag(2, 2, 0, VoxelTag::Interior);
    g.set_tag(2, 2, 1, VoxelTag::Interior);
    for (int j = 0; j < 5; ++j)
      for (int i = 0; i < 5; ++i) g.set_tag(i, j, 2, VoxelTag::Interior);
    // The pillar top (2,2,2) is supported from below; the four shelf voxels
    // orthogonally adjacent to it (1,2,2),(3,2,2),(2,1,2),(2,3,2) are supported at
    // 45 deg by the pillar. The remaining 25 - 1 - 4 = 20 shelf voxels overhang.
    CHECK(support_overhang_voxels(g, Vec3{0, 0, 1}) == 20,
          "floating shelf: 20 overhang voxels beyond the pillar's 45-deg reach");
    // Building along -z the shelf becomes the base slab => no overhang.
    CHECK(support_overhang_voxels(g, Vec3{0, 0, -1}) == 0,
          "floating shelf built -z is fully plate-supported");
  }

  // Argument validation: a zero-length build direction throws.
  {
    VoxelGrid g = solid_grid(2, 2, 2, 1.0);
    bool threw = false;
    try {
      support_overhang_voxels(g, Vec3{0, 0, 0});
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "zero-length build_dir throws");
    // A grid with no solid voxels has no overhangs.
    CHECK(support_overhang_voxels(empty_grid(2, 2, 2, 1.0), Vec3{0, 0, 1}) == 0,
          "an empty grid has zero overhang voxels");
  }
}

// A grid-indexed uniform stress field: every voxel carries the same Voigt tensor.
std::vector<std::array<double, 6>> uniform_stress(const VoxelGrid& g,
                                                  const std::array<double, 6>& s) {
  return std::vector<std::array<double, 6>>(g.voxel_count(), s);
}

// Find the OrientationScore whose build_dir is parallel to `d` (either sign
// treated as distinct: exact direction match within tol).
const OrientationScore& find_dir(const std::vector<OrientationScore>& v,
                                 const Vec3& d) {
  const double dl = length(d);
  const Vec3 u{d.x / dl, d.y / dl, d.z / dl};
  for (const OrientationScore& os : v)
    if (dot(os.build_dir, u) > 1.0 - 1e-6) return os;
  std::fprintf(stderr, "FAIL: direction not found in scored set\n");
  ++g_failures;
  return v.front();
}

void test_max_interlayer_tension() {
  // Uniform field: sigma_xx=0, sigma_yy=10, sigma_zz=1, no shear. The tension
  // across the layer planes is the normal component along the build direction.
  VoxelGrid g = solid_grid(2, 2, 2, 1.0);
  const std::vector<std::array<double, 6>> s =
      uniform_stress(g, {0.0, 10.0, 1.0, 0.0, 0.0, 0.0});

  CHECK(std::fabs(max_interlayer_tension(g, s, Vec3{0, 0, 1}) - 1.0) < 1e-12,
        "build +z reads sigma_zz = 1");
  CHECK(std::fabs(max_interlayer_tension(g, s, Vec3{0, 1, 0}) - 10.0) < 1e-12,
        "build +y reads sigma_yy = 10");
  CHECK(std::fabs(max_interlayer_tension(g, s, Vec3{1, 0, 0}) - 0.0) < 1e-12,
        "build +x reads sigma_xx = 0");
  // Sign of the direction does not matter (n.sigma.n is even in n).
  CHECK(std::fabs(max_interlayer_tension(g, s, Vec3{0, -1, 0}) - 10.0) < 1e-12,
        "build -y reads sigma_yy = 10 (even in n)");
  // Non-unit build_dir is normalized internally.
  CHECK(std::fabs(max_interlayer_tension(g, s, Vec3{0, 5, 0}) - 10.0) < 1e-12,
        "non-unit build_dir normalized");

  // Compression across the layers counts as zero interlayer tension (max(0,.)).
  const std::vector<std::array<double, 6>> comp =
      uniform_stress(g, {0.0, -7.0, 0.0, 0.0, 0.0, 0.0});
  CHECK(max_interlayer_tension(g, comp, Vec3{0, 1, 0}) == 0.0,
        "compression across layers -> 0 interlayer tension");

  // Shear enters via the 2*n_a*n_b*tau terms. Pure shear sigma_xy=4, dir in the
  // xy diagonal (1,1,0)/sqrt2: n.sigma.n = 2*(1/2)*(1/2)*... = 4.
  const std::vector<std::array<double, 6>> sh =
      uniform_stress(g, {0.0, 0.0, 0.0, 4.0, 0.0, 0.0});
  CHECK(std::fabs(max_interlayer_tension(g, sh, Vec3{1, 1, 0}) - 4.0) < 1e-12,
        "pure xy shear -> tension along the +45 deg xy diagonal");
  CHECK(max_interlayer_tension(g, sh, Vec3{1, -1, 0}) == 0.0,
        "pure xy shear -> compression (0) along the -45 deg xy diagonal");

  // Only solid voxels are read: put a huge stress in an Empty voxel and confirm
  // it is ignored.
  VoxelGrid gp = solid_grid(2, 2, 2, 1.0);
  gp.set_tag(0, 0, 0, VoxelTag::Empty);
  std::vector<std::array<double, 6>> mixed =
      uniform_stress(gp, {0.0, 2.0, 0.0, 0.0, 0.0, 0.0});
  mixed[gp.index(0, 0, 0)] = {0.0, 999.0, 0.0, 0.0, 0.0, 0.0};
  CHECK(std::fabs(max_interlayer_tension(gp, mixed, Vec3{0, 1, 0}) - 2.0) < 1e-12,
        "Empty voxel stress is ignored");

  // Argument validation.
  bool threw = false;
  try {
    max_interlayer_tension(g, s, Vec3{0, 0, 0});
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "max_interlayer_tension: zero-length build_dir throws");
  threw = false;
  try {
    max_interlayer_tension(g, uniform_stress(solid_grid(3, 1, 1, 1.0),
                                             {0, 0, 0, 0, 0, 0}),
                           Vec3{0, 0, 1});
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "max_interlayer_tension: stress size mismatch throws");
}

void test_score_orientations() {
  // Solid 2x2x2 box: support_overhang_voxels is 0 for every axis direction (M4.3),
  // so ranking is driven purely by the stress (interlayer-tension) term here.
  VoxelGrid g = solid_grid(2, 2, 2, 1.0);
  const std::vector<std::array<double, 6>> s =
      uniform_stress(g, {0.0, 10.0, 1.0, 0.0, 0.0, 0.0});
  const std::vector<Vec3> cands = {Vec3{1, 0, 0}, Vec3{0, 1, 0}, Vec3{0, 0, 1}};

  const double k = 0.55;  // PLA
  std::vector<OrientationScore> r = score_orientations(g, s, cands, k);
  CHECK(r.size() == 3, "one score per candidate");

  const OrientationScore& sx = find_dir(r, Vec3{1, 0, 0});
  const OrientationScore& sy = find_dir(r, Vec3{0, 1, 0});
  const OrientationScore& sz = find_dir(r, Vec3{0, 0, 1});

  // Raw terms: interlayer tension is sigma_nn (x:0, z:1, y:10); support all 0.
  CHECK(sx.support_voxels == 0 && sy.support_voxels == 0 && sz.support_voxels == 0,
        "solid box: no overhangs for any axis candidate");
  CHECK(std::fabs(sx.interlayer_tension - 0.0) < 1e-12 &&
            std::fabs(sz.interlayer_tension - 1.0) < 1e-12 &&
            std::fabs(sy.interlayer_tension - 10.0) < 1e-12,
        "interlayer tension per candidate matches sigma_nn");

  // z_knockdown penalty = tension * (1/k - 1); responds to the material.
  const double knock = 1.0 / k - 1.0;
  CHECK(std::fabs(sy.stress_penalty - 10.0 * knock) < 1e-12,
        "stress_penalty = interlayer_tension * (1/k - 1)");
  CHECK(sy.stress_penalty > sz.stress_penalty && sz.stress_penalty > sx.stress_penalty,
        "penalty orders x < z < y (follows interlayer tension)");

  // Ranking: lowest interlayer tension wins -> +x best, then +z, then +y.
  CHECK(dot(r.front().build_dir, Vec3{1, 0, 0}) > 1.0 - 1e-6,
        "best candidate is +x (zero interlayer tension)");
  CHECK(sx.score < sz.score && sz.score < sy.score,
        "combined score orders x < z < y");
  // Sorted best-first.
  CHECK(r[0].score <= r[1].score && r[1].score <= r[2].score,
        "result is sorted ascending by score");

  // Mechanism: at z_knockdown = 1.0 (resin) the stress term loses its preference
  // (penalty 0 for every candidate). With support also 0 here, all scores tie 0.
  std::vector<OrientationScore> r1 = score_orientations(g, s, cands, 1.0);
  for (const OrientationScore& os : r1) {
    CHECK(os.stress_penalty == 0.0, "k=1: stress_penalty is 0 (no preference)");
    CHECK(os.score == 0.0, "k=1: no support here -> score 0 for all");
  }

  // Support term alone can still rank: give +z real overhangs via geometry so the
  // support proxy separates candidates, and zero the stress so only support acts.
  // A floating 3x3 shelf on a central pillar (as in the M4.3 support test).
  VoxelGrid gs = empty_grid(3, 3, 3, 1.0);
  gs.set_tag(1, 1, 0, VoxelTag::Interior);       // pillar
  for (int j = 0; j < 3; ++j)
    for (int i = 0; i < 3; ++i) gs.set_tag(i, j, 2, VoxelTag::Interior);  // shelf
  const std::vector<std::array<double, 6>> zero =
      uniform_stress(gs, {0, 0, 0, 0, 0, 0});
  std::vector<OrientationScore> rs =
      score_orientations(gs, zero, {Vec3{0, 0, 1}, Vec3{0, 0, -1}}, 0.55);
  CHECK(dot(rs.front().build_dir, Vec3{0, 0, -1}) > 1.0 - 1e-6,
        "support term alone prefers -z (shelf on the plate, no overhang)");

  // Argument validation.
  auto throws = [&](double kk, double sw, double stw,
                    const std::vector<std::array<double, 6>>& st,
                    const std::vector<Vec3>& cs) {
    try {
      score_orientations(g, st, cs, kk, sw, stw);
    } catch (const std::invalid_argument&) {
      return true;
    }
    return false;
  };
  CHECK(throws(0.55, 1.0, 1.0, s, {}), "empty candidates throws");
  CHECK(throws(0.0, 1.0, 1.0, s, cands), "k = 0 throws");
  CHECK(throws(1.5, 1.0, 1.0, s, cands), "k > 1 throws");
  CHECK(throws(0.55, -1.0, 1.0, s, cands), "negative support_weight throws");
  CHECK(throws(0.55, 1.0, -1.0, s, cands), "negative stress_weight throws");
  CHECK(throws(0.55, 1.0, 1.0,
               uniform_stress(solid_grid(3, 1, 1, 1.0), {0, 0, 0, 0, 0, 0}),
               cands),
        "stress size mismatch throws");
}

}  // namespace

int main() {
  test_flat_face_normals();
  test_orientation_candidates();
  test_support_overhang();
  test_max_interlayer_tension();
  test_score_orientations();

  if (g_failures == 0) {
    std::printf("orientation candidates + support proxy + scoring (M4.3/M4.4): "
                "all %d checks passed\n",
                g_checks);
    return 0;
  }
  std::fprintf(stderr, "orientation (M4.3): %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
