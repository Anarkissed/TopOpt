// test_lattice_void.cpp — THE ENCLOSED-VOID RULE FOR LATTICE
// (task 2026-08-05-lattice-void-reaches-exterior).
//
// THE RULE: the void space inside any lattice must connect to the exterior. No
// sealed lattice-filled cavities.
//
// THIS FILE IS ADVERSARIAL BY CONSTRUCTION in two places, because a connectivity
// check that never refuses is indistinguishable from one that is not wired up:
//
//   * Section A builds a part with a lattice-filled cavity that is sealed on all
//     six sides, and FIRST asserts that the existing pipeline is perfectly happy
//     with it — the certification mask carries it and the generator writes real
//     struts into it. That is the defect, asserted rather than described. Only
//     then does it assert the new check refuses it.
//
//   * Section C builds a cavity whose ONLY path to the outside is a staircase of
//     CORNER touches, and asserts (i) the check still calls it sealed and
//     (ii) a 26-connected fill — computed in this file, on the same grid — calls
//     it OPEN. Without (ii) the test would pass against a permissive
//     implementation that simply refused everything.
//
// Self-contained CHECK harness (ARCHITECTURE §4 locks the dependency set).

#include "topopt/lattice_gen.hpp"
#include "topopt/lattice_void.hpp"
#include "topopt/mesh.hpp"
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

// A fully solid N^3 grid at 1 mm spacing, origin at the origin. Everything is
// printed material until a caller carves void or marks lattice.
VoxelGrid solid_grid(int n) {
  VoxelGrid g;
  g.nx = g.ny = g.nz = n;
  g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Interior);
  return g;
}

bool in_box(int i, int j, int k, int lo, int hi) {
  return i >= lo && i <= hi && j >= lo && j <= hi && k >= lo && k <= hi;
}

// A 26-CONNECTED reachable-set fill over the same escape network, used ONLY as
// the negative control in section C. This is what the check would do if it took
// the load path's adjacency, and section C requires the two to DISAGREE.
long long reached_26(const VoxelGrid& g, const std::vector<double>& dens,
                     double iso, const std::vector<char>& mask) {
  const int nx = g.nx, ny = g.ny, nz = g.nz;
  const std::size_t n = g.voxel_count();
  auto escape = [&](std::size_t e) { return mask[e] || !(dens[e] >= iso); };
  std::vector<char> seen(n, 0);
  std::vector<std::size_t> st;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (i != 0 && i != nx - 1 && j != 0 && j != ny - 1 && k != 0 &&
            k != nz - 1)
          continue;
        const std::size_t e = g.index(i, j, k);
        if (!escape(e) || seen[e]) continue;
        seen[e] = 1;
        st.push_back(e);
      }
  long long latticed = 0;
  while (!st.empty()) {
    const std::size_t e = st.back();
    st.pop_back();
    const int i = static_cast<int>(e % static_cast<std::size_t>(nx));
    const int j = static_cast<int>((e / static_cast<std::size_t>(nx)) %
                                   static_cast<std::size_t>(ny));
    const int k = static_cast<int>(e / (static_cast<std::size_t>(nx) *
                                        static_cast<std::size_t>(ny)));
    if (mask[e]) ++latticed;
    for (int dk = -1; dk <= 1; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          if (!di && !dj && !dk) continue;
          const int ni = i + di, nj = j + dj, nk = k + dk;
          if (ni < 0 || nj < 0 || nk < 0 || ni >= nx || nj >= ny || nk >= nz)
            continue;
          const std::size_t ne = g.index(ni, nj, nk);
          if (!escape(ne) || seen[ne]) continue;
          seen[ne] = 1;
          st.push_back(ne);
        }
  }
  return latticed;
}

// A sink that only counts, for the "the pipeline emits this today" assertion.
struct CountingSink : TriangleSink {
  std::uint64_t tris = 0;
  void add_triangle(const Vec3&, const Vec3&, const Vec3&) override { ++tris; }
};

}  // namespace

int main() {
  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION A — A SEALED LATTICE-FILLED CAVITY.
  // A 20 mm solid cube, every voxel printed. The lattice fills the inner
  // 6x6x6 block (voxels 7..12 on every axis). There is no void anywhere in the
  // part, so the lattice's pore space is walled in by solid on all six sides.
  // ═══════════════════════════════════════════════════════════════════════════
  {
    const int N = 20;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 1.0);
    std::vector<char> mask(g.voxel_count(), 0);
    for (int k = 0; k < N; ++k)
      for (int j = 0; j < N; ++j)
        for (int i = 0; i < N; ++i)
          if (in_box(i, j, k, 7, 12)) mask[g.index(i, j, k)] = 1;

    // ── THE BEFORE. The existing pipeline is entirely happy with this: the
    // certification mask carries all 216 voxels, and the generator writes real
    // struts into them. Nothing in core refuses it. THAT IS THE DEFECT.
    long long masked = 0;
    for (const char c : mask) masked += (c != 0);
    CHECK(masked == 216, "before: the certification mask carries the sealed block");

    LatticeRegion R;
    R.origin = g.origin;
    R.cell_mm = 2.0;
    R.nx = R.ny = R.nz = 10;
    R.latticed = [](int ci, int cj, int ck) {
      // The cells the sealed block owns: voxels 7..12 at 1 mm, cells of 2 mm.
      return ci >= 3 && ci <= 6 && cj >= 3 && cj <= 6 && ck >= 3 && ck <= 6;
    };
    LatticeRadiusField rf;
    rf.uniform_mm = 0.3;
    CountingSink sink;
    const LatticeGenStats st =
        generate_lattice(LatticeGenTopology::Octet, R, rf, sink);
    CHECK(st.struts > 0 && sink.tris > 0,
          "before: the generator emits real struts into the sealed cavity — the "
          "file a slicer opens contains a lattice nothing can ever be emptied "
          "from, and no existing code path says so");

    // ── THE AFTER.
    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 2.0);
    CHECK(r.decidable, "A: the check is decidable — there IS lattice to judge");
    CHECK(r.sealed(), "A: a lattice-filled cavity walled in on all six sides is "
                      "SEALED and must be refused");
    CHECK(r.latticed_voxels == 216, "A: 216 latticed voxels");
    CHECK(r.latticed_sealed == 216, "A: every one of them is sealed");
    CHECK(r.latticed_reached == 0, "A: none of them is reachable");
    CHECK(r.sealed_cells == 64,
          "A: the sealed lattice occupies 4x4x4 = 64 cells of 2 mm");
    CHECK(r.latticed_cells == 64, "A: and those are all the latticed cells");
    CHECK(std::fabs(r.sealed_volume_mm3 - 216.0) < 1e-9,
          "A: 216 voxels of 1 mm^3 = 216 mm^3 trapped");
    CHECK(r.sealed_pockets_with_lattice == 1, "A: exactly one sealed cavity");
    CHECK(r.sealed_pockets_without_lattice == 0,
          "A: and no lattice-free sealed voids");
    CHECK(r.pockets.size() == 1, "A: one pocket is listed");
    if (r.pockets.size() == 1) {
      const SealedVoidPocket& P = r.pockets[0];
      CHECK(P.lo[0] == 7 && P.lo[1] == 7 && P.lo[2] == 7 && P.hi[0] == 12 &&
                P.hi[1] == 12 && P.hi[2] == 12,
            "A: the pocket's voxel bounding box is exactly the block");
      CHECK(std::fabs(P.bbox_min.x - 7.0) < 1e-12 &&
                std::fabs(P.bbox_max.x - 13.0) < 1e-12,
            "A: and in mm it CONTAINS the block (outer corners)");
    }
    CHECK(r.lattice_escape_depth == -1,
          "A: no latticed voxel was reached, so there is no escape depth");
    for (int f = 0; f < 6; ++f)
      CHECK(!r.face_escapes[f], "A: no grid face is an escape route");
    CHECK(!lattice_void_refusal(r).empty(),
          "A: the refusal text is non-empty and names the failure");
    const std::string why = lattice_void_refusal(r);
    CHECK(why.find("216") != std::string::npos &&
              why.find("64") != std::string::npos,
          "A: the refusal names the counts (voxels and cells)");
    CHECK(why.find("bounding box") != std::string::npos,
          "A: the refusal names WHERE");

    // ★ THE REFUSAL MUST BE ACTIONABLE, NOT MERELY CORRECT (task
    // 2026-08-06-arm-projection-and-void-check, S2b). The check is ARMED BY
    // DEFAULT now, so the first person to meet this refusal never opted in to
    // it: they have a run that stopped and no route forward unless the text
    // gives them one. Naming the fault is not enough.
    CHECK(why.find("TO PROCEED") != std::string::npos,
          "A: the refusal states how to CONTINUE, not only what is wrong");
    CHECK(why.find("\"require_lattice_void_reaches_exterior\": false") !=
              std::string::npos,
          "A: the refusal names the exact setting AND the value that turns the "
          "check off");
    CHECK(why.find("sealed lattice cavities") != std::string::npos &&
              why.find("cannot be removed after printing") != std::string::npos,
          "A: the refusal states the CONSEQUENCE of turning it off, so the way "
          "out is an informed choice rather than a way to make a message stop");

    // ★ AND THE ADVICE MUST NOT BE A LOOP. While the default was false,
    // "clear the key" was a correct remedy. The moment the default flipped to
    // true it became wrong: removing the key leaves it at the default, which is
    // ARMED, and the next run refuses identically. This assertion exists so the
    // old wording cannot come back with the new default.
    CHECK(why.find("clear lattice.require_lattice_void_reaches_exterior") ==
              std::string::npos,
          "A: the refusal must NOT tell the user to CLEAR the key — with the "
          "check armed by default, clearing it changes nothing");
    CHECK(why.find("REMOVING the key does not turn it off") != std::string::npos,
          "A: and it says so explicitly, because clearing the key is exactly "
          "what a reader would otherwise try first");

    // Determinism: the reachable SET is order-independent, so a rerun agrees.
    const LatticeVoidEscapeReport r2 =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 2.0);
    CHECK(r2.latticed_sealed == r.latticed_sealed &&
              r2.sealed_cells == r.sealed_cells &&
              r2.bfs_visits == r.bfs_visits,
          "A: deterministic — same counts and same work on a rerun");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION B — AN OPEN LATTICE POCKET STILL PASSES.
  // The rule permits what the maintainer actually wants: a pocket of lattice
  // INSIDE the part, provided its void reaches the surface. Same cube, same
  // inner block, but the block runs out to the +x face.
  // ═══════════════════════════════════════════════════════════════════════════
  {
    const int N = 20;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 1.0);
    std::vector<char> mask(g.voxel_count(), 0);
    for (int k = 7; k <= 12; ++k)
      for (int j = 7; j <= 12; ++j)
        for (int i = 7; i < N; ++i) mask[g.index(i, j, k)] = 1;

    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 2.0);
    CHECK(r.decidable, "B: decidable");
    CHECK(!r.sealed(),
          "B: a lattice pocket that reaches the surface is OPEN and must pass — "
          "the rule permits interior lattice, it forbids SEALED interior lattice");
    CHECK(r.latticed_sealed == 0, "B: nothing sealed");
    CHECK(r.latticed_reached == r.latticed_voxels, "B: all of it is reachable");
    CHECK(r.lattice_escape_depth == 0,
          "B: the lattice itself lies on the boundary plane — depth 0");
    CHECK(r.face_escapes[static_cast<int>(GridFace::PosX)],
          "B: the receipt names +x as the way out");
    CHECK(!r.face_escapes[static_cast<int>(GridFace::NegX)],
          "B: and does NOT claim a way out that does not exist");
    CHECK(lattice_void_refusal(r).empty(), "B: nothing to refuse");
    CHECK(r.reachable_escape_volume_mm3 > 0.0,
          "B: a PASS states how much void was reachable — a silent pass is "
          "indistinguishable from a check that did not run");
  }

  // A pocket that is buried but drains through a void CHANNEL to the surface:
  // the same verdict, and the escape depth says how far in it is.
  {
    const int N = 20;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 1.0);
    std::vector<char> mask(g.voxel_count(), 0);
    for (int k = 0; k < N; ++k)
      for (int j = 0; j < N; ++j)
        for (int i = 0; i < N; ++i)
          if (in_box(i, j, k, 7, 12)) mask[g.index(i, j, k)] = 1;
    // A one-voxel-wide void drain from the block out through the +x face.
    for (int i = 13; i < N; ++i) dens[g.index(i, 9, 9)] = 0.0;

    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 2.0);
    CHECK(!r.sealed(), "B2: a drain channel to the surface opens the cavity");
    CHECK(r.latticed_reached == 216, "B2: the whole block drains");
    CHECK(r.lattice_escape_depth == 7,
          "B2: the drain runs 7 escape steps in from the boundary plane "
          "(x=19 is level 0, x=13 is level 6, the first latticed voxel x=12 is 7)");
    CHECK(r.face_escapes[static_cast<int>(GridFace::PosX)],
          "B2: +x is the way out it found");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION C — ★ A DIAGONAL-ONLY ESCAPE IS NOT AN ESCAPE.
  // The only path from the cavity to the outside is a staircase of voxels that
  // touch each other at CORNERS. They share zero area: nothing flows through it.
  // A 26-connected fill — the adjacency the SOLID load path deliberately uses —
  // calls this open. This check must not.
  // ═══════════════════════════════════════════════════════════════════════════
  {
    const int N = 20;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 1.0);
    std::vector<char> mask(g.voxel_count(), 0);
    for (int k = 0; k < N; ++k)
      for (int j = 0; j < N; ++j)
        for (int i = 0; i < N; ++i)
          if (in_box(i, j, k, 7, 12)) mask[g.index(i, j, k)] = 1;
    // The staircase: (13,13,13), (14,14,14) ... (19,19,19). Each step touches
    // the previous one at a single CORNER, and the first touches the block's
    // corner voxel (12,12,12) at a corner. The last reaches three grid faces.
    for (int t = 13; t < N; ++t) dens[g.index(t, t, t)] = 0.0;

    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 2.0);
    CHECK(r.sealed(),
          "C: a corner-touch staircase is NOT a drain path — the cavity is "
          "still sealed under 6-connectivity");
    CHECK(r.latticed_sealed == 216, "C: the whole block is still sealed");
    CHECK(r.sealed_pockets_with_lattice == 1, "C: one sealed lattice cavity");
    // And the staircase is not one pocket either: under 6-connectivity its own
    // steps do not touch each other, so (13,13,13)..(18,18,18) are six separate
    // one-voxel sealed voids and only (19,19,19) — which lies on three grid
    // faces — is open. Reported (they are real enclosed voids), never a refusal.
    CHECK(r.sealed_pockets_without_lattice == 6,
          "C: the six interior staircase steps are themselves sealed one-voxel "
          "voids, each isolated from its neighbours by the same corner touch");
    CHECK(std::fabs(r.sealed_volume_without_lattice_mm3 - 6.0) < 1e-9,
          "C: 6 mm^3 of lattice-free trapped void");

    // ── THE NEGATIVE CONTROL. The same grid under 26-connectivity: the
    // staircase links the block to the outside and every latticed voxel comes
    // back reachable. Without this line, section C would also pass against an
    // implementation that refused everything.
    const long long open26 = reached_26(g, dens, 0.5, mask);
    CHECK(open26 == 216,
          "C: a 26-connected fill DOES call this cavity open — which is exactly "
          "why the connectivity choice is load-bearing and is asserted here");
    CHECK(r.latticed_reached == 0 && open26 == 216,
          "C: the two adjacencies disagree on this part, and 6 is the "
          "conservative, physical answer");
  }

  // 18-connectivity would also be wrong, for the same reason at half strength:
  // an EDGE contact shares a line, not an area. The check reaches strictly less
  // than a 26-connected fill on every input, which is the safe direction.
  {
    const int N = 12;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 1.0);
    std::vector<char> mask(g.voxel_count(), 0);
    for (int k = 4; k <= 7; ++k)
      for (int j = 4; j <= 7; ++j)
        for (int i = 4; i <= 7; ++i) mask[g.index(i, j, k)] = 1;
    // An EDGE-touching void run: (8,8,k) for k = 4..11 reaches the +z face and
    // touches the block's (7,7,k) column along an edge only.
    for (int k = 4; k < N; ++k) dens[g.index(8, 8, k)] = 0.0;
    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 2.0);
    CHECK(r.sealed(), "C2: an edge-only contact is not an aperture either");
    CHECK(reached_26(g, dens, 0.5, mask) == 64,
          "C2: and a 26-connected fill would have passed it");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION D — VACUITY AND SCOPE.
  // ═══════════════════════════════════════════════════════════════════════════
  {
    // No lattice at all: nothing to decide. The check never invents a verdict it
    // cannot measure — the same discipline walk_load_path applies.
    const int N = 10;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 1.0);
    const std::vector<char> mask(g.voxel_count(), 0);
    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 2.0);
    CHECK(!r.decidable, "D: no lattice => not decidable");
    CHECK(!r.sealed(), "D: and therefore not a refusal");
    CHECK(lattice_void_refusal(r).empty(), "D: nothing to say");
  }
  {
    // A sealed void pocket with NO lattice in it is a real enclosed void, but it
    // is not what THIS rule is about. Reported, never refused — a check that
    // quietly widened its own scope would be a different check.
    const int N = 20;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 1.0);
    std::vector<char> mask(g.voxel_count(), 0);
    for (int k = 2; k <= 4; ++k)
      for (int j = 2; j <= 4; ++j)
        for (int i = 2; i <= 4; ++i) dens[g.index(i, j, k)] = 0.0;  // sealed void
    for (int k = 10; k <= 13; ++k)
      for (int j = 10; j <= 13; ++j)
        for (int i = 10; i < N; ++i) mask[g.index(i, j, k)] = 1;  // OPEN lattice
    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 2.0);
    CHECK(!r.sealed(), "D2: the lattice is open, so this is not a refusal");
    CHECK(r.sealed_pockets_without_lattice == 1,
          "D2: but the lattice-free enclosed void is REPORTED");
    CHECK(std::fabs(r.sealed_volume_without_lattice_mm3 - 27.0) < 1e-9,
          "D2: 3x3x3 = 27 mm^3 of it");
    CHECK(std::fabs(r.sealed_volume_mm3) < 1e-12,
          "D2: and it does NOT count toward the lattice-sealed volume");
  }
  {
    // Two separate sealed lattice cavities are counted separately and both
    // named — an aggregate alone would let a second cavity hide behind a first.
    const int N = 24;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 1.0);
    std::vector<char> mask(g.voxel_count(), 0);
    for (int k = 4; k <= 6; ++k)
      for (int j = 4; j <= 6; ++j)
        for (int i = 4; i <= 6; ++i) mask[g.index(i, j, k)] = 1;
    for (int k = 15; k <= 18; ++k)
      for (int j = 15; j <= 18; ++j)
        for (int i = 15; i <= 18; ++i) mask[g.index(i, j, k)] = 1;
    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 3.0);
    CHECK(r.sealed_pockets_with_lattice == 2, "D3: two sealed cavities");
    CHECK(r.latticed_sealed == 27 + 64, "D3: 27 + 64 latticed voxels sealed");
    CHECK(r.pockets.size() == 2, "D3: both are listed");
    CHECK(r.pockets[0].voxels >= r.pockets[1].voxels,
          "D3: largest trapped volume first");
    CHECK(std::fabs(r.sealed_volume_mm3 - 91.0) < 1e-9, "D3: 91 mm^3 total");
  }
  {
    // Declared include-region attribution: a refusal names the region the user
    // drew, not only a bounding box.
    const int N = 16;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 1.0);
    std::vector<char> mask(g.voxel_count(), 0);
    std::vector<int> rid(g.voxel_count(), 0);
    for (int k = 6; k <= 9; ++k)
      for (int j = 6; j <= 9; ++j)
        for (int i = 6; i <= 9; ++i) {
          mask[g.index(i, j, k)] = 1;
          rid[g.index(i, j, k)] = 3;
        }
    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 2.0, &rid);
    CHECK(r.sealed(), "D4: sealed");
    CHECK(r.pockets.size() == 1 && r.pockets[0].region_ids.size() == 1 &&
              r.pockets[0].region_ids[0] == 3,
          "D4: the pocket names declared include region 3");
    CHECK(lattice_void_refusal(r).find("include region 3") != std::string::npos,
          "D4: and the refusal text says so");
  }
  {
    // Argument validation, so a size mismatch can never be read as "open".
    const int N = 6;
    VoxelGrid g = solid_grid(N);
    const std::vector<double> dens(g.voxel_count(), 1.0);
    const std::vector<char> short_mask(g.voxel_count() - 1, 0);
    bool threw = false;
    try {
      lattice_void_escape(g, dens, 0.5, short_mask, g.origin, 2.0);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "D5: a mask size mismatch throws rather than answering");
    threw = false;
    try {
      const std::vector<char> ok(g.voxel_count(), 0);
      lattice_void_escape(g, dens, 0.5, ok, g.origin, 0.0);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "D5: a non-positive cell_mm throws");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION E — THE CHECK IS NOT THE ISOLATED-FRAGMENT CHECK.
  // Opposite polarity, same machinery. A solid fragment floating in void is
  // attached to nothing — a real defect, and NOT this one. This check must be
  // silent about it, so that when it does speak, it means one thing.
  // ═══════════════════════════════════════════════════════════════════════════
  {
    const int N = 16;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 0.0);  // everything void
    std::vector<char> mask(g.voxel_count(), 0);
    // One solid fragment floating free in the middle, plus an open lattice slab
    // so the check has something to decide.
    for (int k = 6; k <= 8; ++k)
      for (int j = 6; j <= 8; ++j)
        for (int i = 6; i <= 8; ++i) dens[g.index(i, j, k)] = 1.0;
    for (int k = 1; k <= 2; ++k)
      for (int j = 1; j <= 2; ++j)
        for (int i = 0; i < N; ++i) {
          dens[g.index(i, j, k)] = 1.0;
          mask[g.index(i, j, k)] = 1;
        }
    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 4.0);
    CHECK(!r.sealed(),
          "E: a floating SOLID fragment is not a sealed VOID — this check says "
          "nothing about it");
    CHECK(r.sealed_pockets_total == 0, "E: and reports no sealed pocket at all");
    CHECK(r.solid_voxels == 27, "E: the fragment is counted as blocking solid");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION F — COST (bar R5). The flood fill's own work is bounded by the
  // voxel count; it is reported so the check's cost can be read against the run
  // it protects rather than asserted to be small.
  // ═══════════════════════════════════════════════════════════════════════════
  {
    const int N = 32;
    VoxelGrid g = solid_grid(N);
    std::vector<double> dens(g.voxel_count(), 1.0);
    std::vector<char> mask(g.voxel_count(), 0);
    for (int k = 8; k <= 23; ++k)
      for (int j = 8; j <= 23; ++j)
        for (int i = 8; i < N; ++i) mask[g.index(i, j, k)] = 1;
    const LatticeVoidEscapeReport r =
        lattice_void_escape(g, dens, 0.5, mask, g.origin, 4.0);
    const long long n = static_cast<long long>(g.voxel_count());
    CHECK(r.bfs_visits > 0, "F: the check reports the work it did");
    CHECK(r.bfs_visits <= 2 * n,
          "F: every voxel is pushed at most once per pass, and there are two "
          "passes — the fill is O(voxel_count), not a search");
  }

  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
