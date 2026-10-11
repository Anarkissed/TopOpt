// ── K6 PART 2: THE CLIP AND THE OWNER FUNCTION MUST AGREE, POINT FOR POINT ─────
// Where two include prisms overlap, both regions' passes used to lay a lattice through
// the shared volume and the file carried two of them. `stepped_region_owner` already
// answers who owns a point -- among the includes whose region CONTAINS it, the one whose
// FACE PLANE is nearest, exact ties to the lower DECLARED id -- but it is a PREDICATE,
// and a strut clip needs a signed distance.
//
// `LatticeBoundary::clip_to_owned_region` adds that answer as a clip term:
//
//     own_R = min over S != R of  max( -sd_S ,  (d_S - d_R)/2 + bias )
//
// "S does not contest this point" is "S does not contain it" OR "S's plane is farther";
// the min says no S contests it. The HALVED difference is what keeps the term
// 1-Lipschitz (d_S - d_R is 2-Lipschitz), and halving cannot change a sign, so the
// AGREEMENT below is exact rather than approximate: the magnitude is conservative near
// the ownership boundary, the sign is not.
//
// This test is the reviewer's "10,000 random points per shared volume" bar. It runs on
// the two straddler regions (the same geometry as tests/fixtures/organic/straddler_seam):
// A's face plane is y = 0, B's is x = 0, and their prisms overlap over a large volume, so
// a random point is a real test of the rule rather than of one corner.
//
// WHY A UNIT TEST AND NOT A RUN. The agreement is a property of two pure functions over a
// point. Measuring it through a run would sample it only where struts happen to lie, and
// would not reach the tie-break or the no-face-plane case at all.
#include "topopt/clearance.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/stepped_plan.hpp"

#include <cstdio>
#include <random>
#include <vector>

using namespace topopt;

static int g_checks = 0, g_failures = 0;
#define CHECK(cond, what)                                                          \
  do {                                                                             \
    ++g_checks;                                                                    \
    if (!(cond)) {                                                                 \
      ++g_failures;                                                                \
      std::fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, (what));        \
    }                                                                              \
  } while (0)

// One face include, exactly as run_job builds them: the sent geometry through
// resolve_clearance_manual, with the declared id the caller numbered it.
static ClearanceGeometry face_include(const Vec3& origin, const Vec3& normal,
                                      double half_u, double half_w, double depth,
                                      int declared_id) {
  ManualClearanceGeometry m;
  m.kind = ClearanceKind::Face;
  m.origin = origin;
  m.normal = normal;
  m.half_u_mm = half_u;
  m.half_w_mm = half_w;
  ClearanceParams cp;
  cp.kind = ClearanceKind::Face;
  cp.slab_depth_mm = depth;
  ClearanceGeometry g = resolve_clearance_manual(m, cp);
  g.declared_region_id = declared_id;
  return g;
}

int main() {
  // straddler_seam's own two regions.
  const ClearanceGeometry A =
      face_include({4.5, 0.0, 6.5}, {0.0, 1.0, 0.0}, 6.0, 6.0, 12.0, 1);
  const ClearanceGeometry B =
      face_include({0.0, 4.5, 6.5}, {1.0, 0.0, 0.0}, 6.0, 6.0, 12.0, 2);
  CHECK(A.valid && B.valid, "both includes resolve");
  const std::vector<ClearanceGeometry> incs = {A, B};

  // A box base far larger than the prisms, so the base term never binds and what is
  // measured is the ownership term and nothing else.
  auto make = [&incs](int own) {
    LatticeBoundary b;
    b.add_box({-100.0, -100.0, -100.0}, {100.0, 100.0, 100.0});
    for (const ClearanceGeometry& g : incs) b.add_include_region(g);
    b.clip_to_owned_region(own);
    return b;
  };
  const LatticeBoundary bA = make(1);
  const LatticeBoundary bB = make(2);
  LatticeBoundary bNone;
  bNone.add_box({-100.0, -100.0, -100.0}, {100.0, 100.0, 100.0});
  for (const ClearanceGeometry& g : incs) bNone.add_include_region(g);

  // ── 10,000 random points over the two prisms' own extent ────────────────────
  std::mt19937_64 rng(20261010);
  std::uniform_real_distribution<double> ux(-3.0, 13.0), uy(-3.0, 13.0), uz(-1.0, 14.0);
  int in_both = 0, owned_a = 0, owned_b = 0, agree_a = 0, agree_b = 0, mismatch = 0;
  for (int n = 0; n < 10000; ++n) {
    const Vec3 p{ux(rng), uy(rng), uz(rng)};
    const bool pa = point_in_clearance_region(A, p, 0.0);
    const bool pb = point_in_clearance_region(B, p, 0.0);
    if (!(pa && pb)) continue;     // the SHARED volume is what is under test
    ++in_both;
    const int owner = stepped_region_owner(p, incs);
    const double sa = bA.signed_distance(p);
    const double sb = bB.signed_distance(p);
    if (owner == 1) {
      ++owned_a;
      if (sa > 0.0 && sb <= 0.0) ++agree_a; else ++mismatch;
    } else if (owner == 2) {
      ++owned_b;
      if (sb > 0.0 && sa <= 0.0) ++agree_b; else ++mismatch;
    } else {
      ++mismatch;   // a point inside both prisms always has an owner
    }
  }
  std::fprintf(stderr,
               "[k6] %d of 10000 points lie in BOTH prisms: %d owned by region 1, %d by "
               "region 2, %d disagreements with the clip\n",
               in_both, owned_a, owned_b, mismatch);
  // The premise: the shared volume is a real volume and both regions win part of it.
  // Without this, "no disagreements" would be satisfied by a shared volume of zero.
  CHECK(in_both > 1000, "premise: the two prisms really do share a large volume");
  CHECK(owned_a > 100 && owned_b > 100,
        "premise: both regions own a substantial share of it, so the rule is exercised "
        "in both directions");
  CHECK(mismatch == 0,
        "the clip's sign must agree with stepped_region_owner at EVERY shared point: the "
        "region that owns it clips it IN, the other clips it OUT");

  // ── A REGION WITH NO FACE PLANE DOES NOT CONTEST A FACE REGION ───────────────
  // stepped_region_owner says this by giving a plane-less region d = +infinity. The clip
  // must say the same, or a bolt keep-in would delete a face region's lattice.
  {
    ClearanceGeometry noplane = A;
    noplane.normal = Vec3{0.0, 0.0, 0.0};      // no plane: cannot win a shared point
    noplane.declared_region_id = 3;
    std::vector<ClearanceGeometry> two = {B, noplane};
    LatticeBoundary bb;
    bb.add_box({-100.0, -100.0, -100.0}, {100.0, 100.0, 100.0});
    for (const ClearanceGeometry& g : two) bb.add_include_region(g);
    bb.clip_to_owned_region(2);                 // B, which HAS a plane
    int shared = 0, kept = 0;
    std::mt19937_64 r2(7);
    for (int n = 0; n < 10000; ++n) {
      const Vec3 p{ux(r2), uy(r2), uz(r2)};
      if (!point_in_clearance_region(B, p, 0.0)) continue;
      if (!point_in_clearance_region(noplane, p, 0.0)) continue;
      ++shared;
      if (bb.signed_distance(p) > 0.0) ++kept;
    }
    CHECK(shared > 100, "premise: the plane-less region shares volume with B");
    CHECK(kept == shared,
          "a region with no face plane must not clip one point away from a face region");
  }

  // ── AND AN UNARMED BOUNDARY IS UNTOUCHED ────────────────────────────────────
  // clip_to_owned_region(0) is the default; a job that does not ask must get exactly the
  // distance it got before, at every point, which is what keeps a no-overlap job
  // byte-identical.
  {
    std::mt19937_64 r3(99);
    int same = 0, total = 0;
    for (int n = 0; n < 2000; ++n) {
      const Vec3 p{ux(r3), uy(r3), uz(r3)};
      ++total;
      LatticeBoundary zero = bNone;
      zero.clip_to_owned_region(0);
      if (zero.signed_distance(p) == bNone.signed_distance(p)) ++same;
    }
    CHECK(same == total, "clip_to_owned_region(0) adds nothing, at every point");
  }

  std::fprintf(stderr, "%s: %d checks, %d failure(s)\n", __FILE__, g_checks, g_failures);
  if (g_failures == 0) std::fprintf(stderr, "all %d checks passed\n", g_checks);
  return g_failures == 0 ? 0 : 1;
}
