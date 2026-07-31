// test_orient_invariants — the ORIENTATION-SWEEP invariants, pinned (task
// 2026-08-01-orientation-scoring-probe, bar S2).
//
// The probe (tests/harness/orientation_scoring_probe.cpp) scores every candidate
// build direction against ONE solved stress field. That is only sound while a
// short list of structural facts holds, and a probe whose invariants drift is
// measuring its own bugs. This test moves those facts into CI so a future change
// to the strut law, the generator's traversal, or the candidate set breaks HERE —
// loudly and cheaply — instead of silently turning an orientation sweep into
// noise. It adds no production code and gates nothing.
//
// WHAT IS PINNED, AND WHY IT MATTERS:
//
//   1. S-c IS INVARIANT IN n, EXACTLY. The strut IN-PLANE bound is a function of
//      the macro rotation invariants (von Mises, pressure) only, so re-evaluating
//      one field against 200+ build directions must return a BIT-IDENTICAL
//      margin. Not "within tolerance" — bit-identical. If this ever moves, some
//      direction-dependent term has leaked into the in-plane path.
//
//   2. THE SIX CUBE AXES AGREE, EXACTLY. PR 263's law is worst-case over macro
//      states with the build axis ON a lattice cube axis, and octet is cubic, so
//      +/-x, +/-y and +/-z must give the SAME interlayer bound and a cross factor
//      of exactly 0. (test_strut_strength pins x vs z; this pins all six, which
//      is the identity an orientation sweep actually relies on.)
//
//   3. OFF-AXIS IS STRICTLY WORSE, NEVER BETTER. The cross term (2/sqrt(3))*
//      (|nx ny| + |ny nz| + |nz nx|) is non-negative and ADDS, so no build
//      direction can improve the strut interlayer margin over a cube axis. This
//      is the specific wrong result the probe was warned about; it is asserted
//      over a dense direction sample, not argued.
//
//   4. THE OCTET STRUT POPULATION IS THE SIX <110> AXES, IN EQUAL MEASURE, and
//      the emitted-fragment count over an n^3 block is EXACTLY 24n^3 + 12n^2 (24
//      legs owned per cell + 12 shared across each boundary face => PR 201's 36
//      per cell). Measured from the REAL generator through LatticeGenObserver,
//      because S-e's whole conclusion — that a cube-axis build leaves exactly one
//      third of the strut length horizontal and that NO orientation lifts every
//      family to the 45-degree self-supporting limit — rests on this population.
//
//   5. THE CANDIDATE SET CONTAINS ALL SIX CUBE AXES for a real part, so the
//      identity in (2) is actually exercised by a sweep.
//
// Self-contained CHECK harness (ARCHITECTURE §4), public API only. Pure C++/std
// (strut_strength.cpp, lattice_gen.cpp and orient.cpp carry no Eigen), so it runs
// in every configuration like test_orient.

#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/orient.hpp"
#include "topopt/strut_strength.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
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

constexpr double kPi = 3.14159265358979323846;

double dot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
double norm(const Vec3& a) { return std::sqrt(dot(a, a)); }
Vec3 unit(const Vec3& a) {
  const double n = norm(a);
  return Vec3{a.x / n, a.y / n, a.z / n};
}

// A dense, deterministic direction sample over the sphere (golden-angle spiral —
// no RNG, so the test is reproducible to the bit).
std::vector<Vec3> sphere_sample(int count) {
  std::vector<Vec3> out;
  out.reserve(static_cast<std::size_t>(count));
  const double ga = kPi * (3.0 - std::sqrt(5.0));
  for (int s = 0; s < count; ++s) {
    const double z = 1.0 - 2.0 * (s + 0.5) / count;
    const double r = std::sqrt(std::max(0.0, 1.0 - z * z));
    const double th = ga * s;
    out.push_back(Vec3{r * std::cos(th), r * std::sin(th), z});
  }
  return out;
}

// A small latticed field: 2x2x2 voxels, all octet at rho 0.30, carrying a macro
// stress state with BOTH a deviatoric and a hydrostatic part (the two-invariant
// law needs both to be exercised) and genuine shear, so a direction-dependent
// term anywhere in the in-plane path would show up.
struct Field {
  std::vector<double> stress;
  std::vector<char> mask;
  std::vector<double> rho;
};

Field make_field() {
  Field f;
  const std::size_t n = 8;
  f.mask.assign(n, 1);
  f.rho.assign(n, 0.30);
  f.stress.assign(6 * n, 0.0);
  // Voigt [xx, yy, zz, xy, yz, zx], TRUE shear, MPa. A different state per voxel
  // so the argmax is a real search, not a constant.
  const double base[6] = {12.0, -5.0, 3.0, 4.0, -2.0, 1.5};
  for (std::size_t e = 0; e < n; ++e)
    for (int c = 0; c < 6; ++c)
      f.stress[6 * e + static_cast<std::size_t>(c)] =
          base[c] * (1.0 + 0.15 * static_cast<double>(e));
  return f;
}

// A mesh with a real flat face on every cube axis (a unit box), so
// orientation_candidates returns the full sphere sampling.
TriangleMesh box_mesh() {
  TriangleMesh m;
  const Vec3 v[8] = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0},
                     {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}};
  for (const Vec3& p : v) m.vertices.push_back(p);
  const int tri[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7},
                          {0, 1, 5}, {0, 5, 4}, {1, 2, 6}, {1, 6, 5},
                          {2, 3, 7}, {2, 7, 6}, {3, 0, 4}, {3, 4, 7}};
  for (const auto& t : tri) m.triangles.push_back({t[0], t[1], t[2]});
  return m;
}

bool is_cube_axis(const Vec3& n) {
  const double a = std::fabs(n.x), b = std::fabs(n.y), c = std::fabs(n.z);
  return (a > 1.0 - 1e-9 && b < 1e-9 && c < 1e-9) ||
         (b > 1.0 - 1e-9 && a < 1e-9 && c < 1e-9) ||
         (c > 1.0 - 1e-9 && a < 1e-9 && b < 1e-9);
}

// ---------------------------------------------------------------------------
// 1 + 2 + 3: the strut-law invariants an orientation sweep rests on.
// ---------------------------------------------------------------------------
void test_strut_law_invariants() {
  const Field f = make_field();
  const double yield = 55.0, zk = 0.55;

  // (2) The six cube axes, EXACTLY equal, cross factor exactly 0.
  const Vec3 axes[6] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
                        {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
  StrutStrengthReport ref =
      evaluate_strut_strength(f.stress, f.mask, f.rho, axes[0], yield, zk);
  CHECK(ref.evaluated, "the law evaluated on the reference axis");
  CHECK(ref.build_dir_on_lattice_axis, "+x is detected as a lattice axis");
  for (const Vec3& a : axes) {
    const StrutStrengthReport r =
        evaluate_strut_strength(f.stress, f.mask, f.rho, a, yield, zk);
    CHECK(r.il_cross_factor == 0.0,
          "cube axis: the interlayer cross factor is exactly 0");
    CHECK(r.build_dir_on_lattice_axis, "cube axis: detected as a lattice axis");
    CHECK(r.margin_interlayer == ref.margin_interlayer,
          "all six cube axes give a BIT-IDENTICAL strut interlayer margin");
    CHECK(r.il_bound_max_mpa == ref.il_bound_max_mpa,
          "all six cube axes give a BIT-IDENTICAL strut interlayer BOUND");
    CHECK(r.margin_in_plane == ref.margin_in_plane,
          "all six cube axes give a BIT-IDENTICAL strut in-plane margin");
  }

  // (1) + (3) over a dense sample: in-plane bit-identical, interlayer never better.
  const std::vector<Vec3> dirs = sphere_sample(257);
  int off_axis = 0, strictly_worse = 0, improved = 0;
  bool in_plane_exact = true;
  for (const Vec3& d : dirs) {
    const StrutStrengthReport r =
        evaluate_strut_strength(f.stress, f.mask, f.rho, d, yield, zk);
    if (r.margin_in_plane != ref.margin_in_plane) in_plane_exact = false;
    if (r.vm_bound_max_mpa != ref.vm_bound_max_mpa) in_plane_exact = false;
    if (r.vm_argmax_voxel != ref.vm_argmax_voxel) in_plane_exact = false;
    if (is_cube_axis(unit(d))) continue;
    ++off_axis;
    CHECK(r.il_cross_factor > 0.0, "off-axis: the cross factor is positive");
    if (r.margin_interlayer < ref.margin_interlayer) ++strictly_worse;
    if (r.margin_interlayer > ref.margin_interlayer) ++improved;
  }
  CHECK(in_plane_exact,
        "S-c: the strut IN-PLANE margin, bound and argmax are BIT-IDENTICAL for "
        "every build direction");
  CHECK(off_axis > 200, "the sample is dominated by off-axis directions");
  CHECK(improved == 0,
        "S-d: NO build direction improves the strut interlayer margin over a "
        "cube axis (the cross term only ADDS)");
  CHECK(strictly_worse == off_axis,
        "S-d: EVERY off-axis direction is strictly worse than a cube axis");

  // The cross term's own algebra, at the extremes: 0 on an axis, maximal on the
  // body diagonal (2/sqrt(3) * 3 * 1/3 = 2/sqrt(3)).
  const StrutStrengthReport diag = evaluate_strut_strength(
      f.stress, f.mask, f.rho, unit(Vec3{1, 1, 1}), yield, zk);
  CHECK(std::fabs(diag.il_cross_factor - 2.0 / std::sqrt(3.0)) < 1e-12,
        "the body diagonal carries the MAXIMAL cross factor 2/sqrt(3)");
  CHECK(!diag.build_dir_on_lattice_axis,
        "the body diagonal is NOT flagged as a lattice axis");
  std::printf(
      "  strut-law invariants: in-plane bit-identical over %zu directions; "
      "%d/%d off-axis strictly worse, %d improved; cube-axis margin %.8f, body "
      "diagonal %.8f\n",
      dirs.size(), strictly_worse, off_axis, improved, ref.margin_interlayer,
      diag.margin_interlayer);
}

// ---------------------------------------------------------------------------
// 4: the octet strut population, measured from the REAL generator.
// ---------------------------------------------------------------------------
struct DiscardSink : TriangleSink {
  void add_triangle(const Vec3&, const Vec3&, const Vec3&) override {}
};

void test_octet_strut_population() {
  struct Axis {
    Vec3 dir;
    double length;
    int count;
  };

  auto measure = [](int cells, std::vector<Axis>* axes) {
    LatticeRegion region;
    region.nx = region.ny = region.nz = cells;
    region.cell_mm = 4.0;
    LatticeRadiusField radius;
    radius.uniform_mm = 0.48;
    long long struts = 0;
    LatticeGenObserver obs;
    obs.on_element = [&](LatticeGenElement kind, const Vec3& a, const Vec3& b,
                         double) {
      if (kind != LatticeGenElement::InteriorStrut) return;
      const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
      const double len = norm(d);
      if (len <= 1e-12) return;
      Vec3 u{d.x / len, d.y / len, d.z / len};
      if (u.x < -1e-12 ||
          (std::fabs(u.x) <= 1e-12 &&
           (u.y < -1e-12 || (std::fabs(u.y) <= 1e-12 && u.z < 0))))
        u = Vec3{-u.x, -u.y, -u.z};
      ++struts;
      if (!axes) return;
      for (Axis& s : *axes)
        if (std::fabs(dot(s.dir, u)) > 1.0 - 1e-9) {
          s.length += len;
          ++s.count;
          return;
        }
      axes->push_back(Axis{u, len, 1});
    };
    DiscardSink sink;
    generate_lattice(LatticeGenTopology::Octet, region, radius, sink,
                     LatticeSkinSpec{}, &obs);
    return struts;
  };

  // The exact emitted-fragment law: 24 legs owned per cell + 12 shared across
  // each of the 6n^2 boundary faces => 24n^3 + 12n^2. 24 + 12 = PR 201's 36.
  for (int n : {1, 2, 3, 4, 6}) {
    const long long got = measure(n, nullptr);
    const long long want = 24LL * n * n * n + 12LL * n * n;
    CHECK(got == want,
          "octet emits exactly 24n^3 + 12n^2 interior strut fragments");
    if (got != want)
      std::fprintf(stderr, "   n=%d got %lld want %lld\n", n, got, want);
  }

  std::vector<Axis> axes;
  measure(4, &axes);
  CHECK(axes.size() == 6,
        "the octet strut population reduces to exactly SIX distinct axes");
  double total = 0.0;
  for (const Axis& a : axes) total += a.length;
  for (const Axis& a : axes) {
    // Every axis is a <110> face diagonal: exactly one zero component, the other
    // two of magnitude 1/sqrt(2).
    const double c[3] = {std::fabs(a.dir.x), std::fabs(a.dir.y),
                         std::fabs(a.dir.z)};
    int zeros = 0, halves = 0;
    for (double v : c) {
      if (v < 1e-9) ++zeros;
      if (std::fabs(v - std::sqrt(0.5)) < 1e-9) ++halves;
    }
    CHECK(zeros == 1 && halves == 2,
          "each octet strut axis is a <110> face diagonal");
    CHECK(std::fabs(a.length / total - 1.0 / 6.0) < 1e-9,
          "the six strut axes carry EQUAL length share (1/6 each)");
  }

  // PR 201's picture, reproduced: a +z build leaves exactly one third of the
  // strut length HORIZONTAL, and the rest sits at exactly 45 degrees — the octet
  // has NO vertical struts in a cube-axis build.
  const Vec3 nz{0, 0, 1};
  double horiz = 0.0, at45 = 0.0, vertical = 0.0;
  for (const Axis& a : axes) {
    const double phi = std::asin(std::min(1.0, std::fabs(dot(a.dir, nz)))) *
                       180.0 / kPi;
    if (phi < 1e-9) horiz += a.length;
    else if (std::fabs(phi - 45.0) < 1e-9) at45 += a.length;
    if (phi > 90.0 - 1e-9) vertical += a.length;
  }
  CHECK(std::fabs(horiz / total - 1.0 / 3.0) < 1e-12,
        "+z build: exactly 1/3 of the octet strut length is HORIZONTAL (PR 201's "
        "12 of 36)");
  CHECK(std::fabs(at45 / total - 2.0 / 3.0) < 1e-12,
        "+z build: exactly 2/3 of the strut length sits at 45 degrees (PR 201's "
        "24 of 36)");
  CHECK(vertical == 0.0,
        "+z build: the octet has NO vertical struts (PR 201's finding)");

  // The exhaustive claim S-e rests on: no build direction lifts EVERY strut
  // family to the 45-degree self-supporting limit. The best achievable elevation
  // of the flattest family is ~18.4 degrees.
  double best_min_phi = -1.0;
  for (const Vec3& d : sphere_sample(200000)) {
    double mn = 90.0;
    for (const Axis& a : axes)
      mn = std::min(mn, std::asin(std::min(1.0, std::fabs(dot(a.dir, d)))) *
                            180.0 / kPi);
    best_min_phi = std::max(best_min_phi, mn);
  }
  CHECK(best_min_phi < 45.0,
        "NO build direction lifts every octet strut family to the 45-degree "
        "self-supporting limit");
  CHECK(best_min_phi > 18.0 && best_min_phi < 19.0,
        "the flattest strut family tops out at ~18.4 degrees above the plate");
  std::printf(
      "  octet population: 6 <110> axes at 1/6 length each; +z gives 1/3 "
      "horizontal, 2/3 at 45 deg, 0 vertical; best achievable flattest-family "
      "elevation %.2f deg\n",
      best_min_phi);
}

// ---------------------------------------------------------------------------
// 5: the candidate set exercises the identity.
// ---------------------------------------------------------------------------
void test_candidate_set_covers_cube_axes() {
  const std::vector<Vec3> cands = orientation_candidates(box_mesh());
  int axes_found = 0;
  for (const Vec3& c : cands)
    if (is_cube_axis(unit(c))) ++axes_found;
  CHECK(axes_found == 6,
        "the candidate set contains all six cube axes (so the S-d identity is "
        "actually swept)");
  CHECK(cands.size() >= 26, "the candidate set includes the sphere sampling");
  std::printf("  candidate set: %zu directions, %d of them cube axes\n",
              cands.size(), axes_found);
}

}  // namespace

int main() {
  test_strut_law_invariants();
  test_octet_strut_population();
  test_candidate_set_covers_cube_axes();
  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
