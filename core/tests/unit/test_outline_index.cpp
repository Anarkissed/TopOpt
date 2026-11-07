// ── THE OUTLINE INDEX'S WALK IS BOUNDED, AND STILL EXACT ──────────────────────
// 102117B9's Default Grade plan ran for ELEVEN HOURS without finishing once ruling 1 let
// it past the ungradeable gate. `sample` put 2504 of 2504 samples in one place:
//
//   clip_segment -> include_signed_distance -> LatticeOutlineIndex::min_distance
//
// The walk steps Chebyshev rings outward from the query's own cell and breaks when
// `best <= ring * cell`. But `best` starts at infinity, so nothing can break it until the
// first EDGE is found, and the bound was `max(na, nb) + max(|qi|, |qj|) + 1`. |qi| counts
// CELLS from that outline, so for a query far outside it -- which is most of a part with
// 177 regions -- it ran into the thousands: O(span^2) empty visits, per query, per
// region, times every refinement step of every strut's clip.
//
// ★ WHY THE ISOLATED MEASUREMENT MISSED IT. The 4.264 us/query figure in 91abe169's note
// was measured over the include regions' OWN bounding box, where |qi| is small. The
// pathology is the far field. That was a measurement-design error, not bad luck: the
// sample distribution flattered the index. So this test measures BOTH fields, and the
// far one first.
//
// THE FIX, in three exact parts: start the walk at the Chebyshev distance from the query
// cell to the index's own box (the rings before it are provably empty), stop it
// max(na, nb) later (by then every grid cell is covered), and walk each ring as a
// PERIMETER rather than sweeping its whole block. All three change the work, none changes
// the answer -- which is what the exactness check below is for.
#include "topopt/clearance.hpp"
#include "topopt/lattice_boundary.hpp"

#include <cmath>
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

// One outlined face include, built the way run_job builds them.
static ClearanceGeometry outlined_face() {
  ManualClearanceGeometry m;
  m.kind = ClearanceKind::Face;
  m.origin = Vec3{0.0, 0.0, 0.0};
  m.normal = Vec3{0.0, 1.0, 0.0};
  m.half_u_mm = 12.0;
  m.half_w_mm = 12.0;
  // A concave outline, so the nearest edge is not simply the nearest vertex and the
  // distance has to be a real segment distance.
  m.outline_uv = {{{-8.0, -8.0}, {8.0, -8.0}, {8.0, 0.0}, {0.0, 0.0},
                   {0.0, 8.0}, {-8.0, 8.0}}};
  ClearanceParams cp;
  cp.kind = ClearanceKind::Face;
  cp.slab_depth_mm = 10.0;
  ClearanceGeometry g = resolve_clearance_manual(m, cp);
  g.declared_region_id = 1;
  return g;
}

int main() {
  const ClearanceGeometry inc = outlined_face();
  CHECK(inc.valid, "the include resolves");
  CHECK(!inc.outline_uv.empty(), "and it carries an outline, so the clip term applies");

  LatticeBoundary b;
  b.add_box({-1e4, -1e4, -1e4}, {1e4, 1e4, 1e4});
  b.add_include_region(inc);

  // ── THE FAR FIELD: THE VISIT CAP ────────────────────────────────────────────
  // A query 400 mm away in plane. The outline's own box is 16 x 16 mm and its index cell
  // is a fraction of that, so the OLD walk had thousands of empty rings to cross before
  // it could find an edge; the bounded walk crosses none of them. The cap is deliberately
  // loose -- it is the difference between hundreds and millions that matters, not a tight
  // constant that a re-tessellation could break.
  lattice_outline_reset_ring_steps();
  const double far_sd = b.signed_distance({400.0, 5.0, 0.0});
  const long long far_rings = lattice_outline_ring_steps();
  std::fprintf(stderr, "[idx] one far query took %lld ring step(s)\n", far_rings);
  CHECK(far_rings > 0,
        "premise: the far query really did reach the outline index -- a zero here would "
        "mean the term was skipped and the cap proved nothing");
  CHECK(far_rings < 50,
        "a far query must not step through the empty space between the point and the "
        "outline. This is the eleven-hour hang, and it is a COUNT, not a stopwatch: the "
        "old walk starts at ring 0 whatever the distance, so its ring count grows with "
        "|qi| -- 76 steps on this small fixture, and |qi| on his part is far larger. The "
        "bounded walk starts at the first ring that can hold an edge.");
  CHECK(std::isfinite(far_sd), "and it still returns a finite distance");

  // ── EXACTNESS: BIT-IDENTICAL, NEAR AND FAR ──────────────────────────────────
  // The reference is the exact unindexed distance -- clearance_outline_signed_distance,
  // which scans every edge and uses no index at all. Bit-identical, not within a
  // tolerance: both compute the same minimum over the same segments in the same order,
  // and the bounds only skip cells that are provably empty. A tolerance here would hide
  // exactly the kind of drift it should catch.
  std::mt19937_64 rng(20261024);
  int near_n = 0, far_n = 0, mismatch = 0;
  double worst = 0.0;
  for (int pass = 0; pass < 2; ++pass) {
    const double reach = pass == 0 ? 20.0 : 600.0;   // near field, then far
    std::uniform_real_distribution<double> u(-reach, reach);
    for (int n = 0; n < 4000; ++n) {
      const double du = u(rng), dw = u(rng);
      // ★ THE POINT IS BUILT FROM THE GEOMETRY'S OWN AXES, NOT FROM A GUESS AT THEM.
      // My second cut passed (p.x, p.z) as (du, dw), assuming core's in-plane basis for a
      // +y normal was (x, z). It is (z, x), so every comparison was reading the concave
      // outline mirrored and 769 points "disagreed" by up to 4.79 mm. The walk was right
      // both times; the test was wrong twice. Constructing the point FROM inc.u and
      // inc.w cannot be wrong about the convention, because it does not state one.
      // ★ MID-DEPTH, NOT ON THE FACE. The boundary's include term is
      // min(depth terms, in-plane term), so a point ON the face plane has a depth term of
      // 0 and the comparison measures the depth, not the outline. My first cut put the
      // point at y = 0 and read 476 "mismatches" with a worst delta of 3.94 mm -- the
      // test was wrong, not the walk. At mid-depth the depth term is 5 mm and the
      // in-plane term is the binding one wherever it is smaller.
      const Vec3 p{inc.origin.x + du * inc.u.x + dw * inc.w.x + 5.0 * inc.normal.x,
                   inc.origin.y + du * inc.u.y + dw * inc.w.y + 5.0 * inc.normal.y,
                   inc.origin.z + du * inc.u.z + dw * inc.w.z + 5.0 * inc.normal.z};
      // Through the boundary (indexed) and through clearance.cpp (unindexed). Both are
      // signed the same way, so a mismatch is a real disagreement.
      const double indexed = b.signed_distance(p);
      const double exact_in_plane = clearance_outline_signed_distance(inc, du, dw);
      // Skip only the case where the point is INSIDE the outline and deeper into it than
      // the depth term, where min() legitimately picks the depth. Everything else --
      // every point outside the outline, near or far -- is compared.
      if (exact_in_plane > 4.0) continue;
      if (pass == 0) ++near_n; else ++far_n;
      const double d = std::fabs(std::fabs(indexed) - std::fabs(exact_in_plane));
      if (d > worst) worst = d;
      if (!(d == 0.0)) ++mismatch;
    }
  }
  std::fprintf(stderr,
               "[idx] exactness: %d near + %d far points compared, %d mismatch(es), "
               "worst |delta| %.17g\n", near_n, far_n, mismatch, worst);
  CHECK(near_n > 100 && far_n > 100,
        "premise: both fields were actually sampled -- the far one is the one the "
        "original measurement missed");
  CHECK(mismatch == 0,
        "the indexed walk must agree with the unindexed scan BIT-EXACTLY, near and far: "
        "the bounds skip only provably empty cells, so there is nothing to round");

  std::fprintf(stderr, "%s: %d checks, %d failure(s)\n", __FILE__, g_checks, g_failures);
  if (g_failures == 0) std::fprintf(stderr, "all %d checks passed\n", g_checks);
  return g_failures == 0 ? 0 : 1;
}
