// THE CONNECTION RULE (ruling 2026-10-25, core-loose-pieces): a piece of material
// that is not connected through solid to a support or a load carries no load,
// whatever its size, so EVERY solve takes it out of the system (it is solved at
// the floor modulus) and no solver path ever sees an unsupported piece.
//
// The motivating run: his Fine strengthen job (Carriage Arms, worker job
// 8bc1e265, core 180a23637fc6) hung 40 minutes in the Jacobi-CG fallback. Its
// first fine solve held 2,031 unanchored pieces; the old size rule (<= 27
// voxels, an ABSOLUTE count), the hinge rule and the frozen rule kept 732 of
// them in the system, the l1 MG-PCG diverged and the fallback had no limit.
//
// The fixture: a 7 x 7 beam (E0) along x through a 64 x 32 x 32 box of floor
// material (1e-9 E0), clamped at its x = 0 end face only and loaded at its tip,
// with ~290 LOOSE pieces planted on a checkerboard of 4-voxel slots around it:
//   * single voxels, 1x1x2 bars, 2x2x2 and 3x3x2 blocks, 3x3x3 (27) cubes;
//   * 7x3x3 = 63-voxel bars (> 27: the old size rule kept them);
//   * hinged pairs — a 2x2x2 block and a voxel touching it at a corner or along
//     an edge, hinged to EACH OTHER but to nothing anchored (the old hinge rule
//     kept both; under the FACE rule they are two loose pieces);
//   * one loose FROZEN piece (a 2x2x2 block at E0, registered in the run's
//     frozen mask the way plsm_optimize registers its FrozenSolid set; the old
//     frozen rule kept it).
// Moduli alternate 0.5 E0 / E0.
//
//   L1  every planted loose voxel — big, hinged and frozen ones included — is
//       solved at the floor modulus, and nothing else is;
//   L2  the solve converges on multigrid (NO Jacobi-CG fallback), and
//   L3  it is BIT-IDENTICAL to the same beam with no pieces planted at all
//       (the loose voxels at the floor are exactly the void around them), in the
//       same number of MG cycles: the loose pieces cost the solver nothing.
//   L4  the classification is by FACE connection (reviewer's ruling 2026-10-26
//       00:08 UTC): a cube touching the beam only at a CORNER and a bar touching
//       it only along an EDGE are hinges, carry no load and are LOOSE; a cube
//       sharing a FACE with the beam is part of it; a piece holding a loaded
//       node is anchored.
// RED on 322b1c78 (core 180a23637fc6): L1 and L3 fail (the old rule kept the
// big, hinged and frozen pieces in the system).

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"
#ifdef TOPOPT_LOOSE_PIECE_RULE
#include "fea/geneo.hpp"
#endif

#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

namespace {

int g_failures = 0;

void check(bool ok, const char* what) {
  std::printf("%s %s\n", ok ? "ok:  " : "FAIL:", what);
  if (!ok) ++g_failures;
}

constexpr double kE0 = 1000.0;
constexpr double kFloor = 1e-9 * kE0;
constexpr double kNu = 0.38;  // PA12-CF, the material of the hung job

struct Fixture {
  VoxelGrid g;
  std::vector<double> ey;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::vector<char> frozen;      // the run's frozen mask
  std::vector<char> planted;     // planted LOOSE voxels
  int pieces = 0;                // planted loose pieces (face-connected)
  long long voxels = 0;          // planted loose voxels
  int big = 0, hinged = 0, frozen_pieces = 0;
};

bool in_beam(int j, int k) { return j >= 12 && j < 19 && k >= 12 && k < 19; }

Fixture make_fixture(bool plant) {
  Fixture F;
  VoxelGrid& g = F.g;
  g.nx = 64;
  g.ny = 32;
  g.nz = 32;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Interior);
  F.ey.assign(g.voxel_count(), kFloor);
  F.frozen.assign(g.voxel_count(), 0);
  F.planted.assign(g.voxel_count(), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (in_beam(j, k)) F.ey[g.index(i, j, k)] = kE0;
  // Clamp the beam's x = 0 END FACE only (a full x = 0 clamp would anchor
  // every piece in the first slot column).
  for (int c = 12; c <= 19; ++c)
    for (int b = 12; b <= 19; ++b) {
      const int nd = topopt::fea_node_index(g, 0, b, c);
      for (int d = 0; d < 3; ++d) F.bcs.push_back({nd, d, 0.0});
    }
  for (int c = 12; c <= 19; ++c)
    for (int b = 12; b <= 19; ++b)
      F.loads.push_back({topopt::fea_node_index(g, g.nx, b, c), 2, -1.0});
  if (!plant) return F;

  auto put = [&](int i, int j, int k, double E) {
    const std::size_t e = g.index(i, j, k);
    F.ey[e] = E;
    F.planted[e] = 1;
    ++F.voxels;
  };
  auto block = [&](int i0, int j0, int k0, int a, int b, int c, double E) {
    for (int k = k0; k < k0 + c; ++k)
      for (int j = j0; j < j0 + b; ++j)
        for (int i = i0; i < i0 + a; ++i) put(i, j, k, E);
  };
  // Slots of 4 voxels; a piece is at most 3 wide inside its slot, so pieces in
  // different slots never share a node. Slots 3 and 4 in y and z hold the beam
  // (y, z in [12, 19)); slot 2's pieces end at voxel 10 and slot 5's start at
  // 20, each a voxel clear of it. Checkerboard:
  // a used slot's face neighbours are free, which is what lets a 63-voxel bar
  // run on into the next x slot.
  bool frozen_done = false;
  for (int sz = 0; sz < 8; ++sz)
    for (int sy = 0; sy < 8; ++sy)
      for (int sx = 0; sx < 16; ++sx) {
        if (sy == 3 || sy == 4 || sz == 3 || sz == 4) continue;
        if ((sx + sy + sz) % 2 != 0) continue;
        const int o = 4 * sx, p = 4 * sy, q = 4 * sz;
        const double E = ((sx + 2 * sy + 3 * sz) % 2 == 0) ? 0.5 * kE0 : kE0;
        if (!frozen_done && sx == 6 && sy == 6 && sz == 0) {
          block(o, p, q, 2, 2, 2, kE0);  // the loose FROZEN piece
          for (int k = q; k < q + 2; ++k)
            for (int j = p; j < p + 2; ++j)
              for (int i = o; i < o + 2; ++i) F.frozen[g.index(i, j, k)] = 1;
          frozen_done = true;
          ++F.frozen_pieces;
          ++F.pieces;
          continue;
        }
        const int h = (sx * 7 + sy * 13 + sz * 29) % 10;
        switch (h) {
          case 0: case 1: case 2: put(o, p, q, E); break;
          case 3: block(o, p, q, 1, 1, 2, E); break;
          case 4: block(o, p, q, 2, 2, 2, E); break;
          case 5: block(o, p, q, 3, 3, 3, E); break;
          case 6:
            if (sx + 1 < 16) {
              block(o, p, q, 7, 3, 3, E);  // 63 voxels, into the free next slot
              ++F.big;
            } else {
              block(o, p, q, 3, 3, 3, E);
            }
            break;
          case 7:  // corner hinge: shares one node with the block (2 pieces)
            block(o, p, q, 2, 2, 2, E);
            put(o + 2, p + 2, q + 2, E);
            ++F.hinged;
            ++F.pieces;
            break;
          case 8:  // edge hinge: shares two nodes with the block (2 pieces)
            block(o, p, q, 2, 2, 2, E);
            put(o + 2, p + 2, q, E);
            ++F.hinged;
            ++F.pieces;
            break;
          default: block(o, p, q, 3, 3, 2, E); break;
        }
        ++F.pieces;
      }
  return F;
}

#ifdef TOPOPT_LOOSE_PIECE_RULE
bool st_warned_once() {
  return topopt::fea_detail::mg_loose_stats().majority_warnings == 1;
}
#endif

bool bit_identical(const FeaSolution& a, const FeaSolution& b) {
  return a.u.size() == b.u.size() &&
         std::memcmp(a.u.data(), b.u.data(), a.u.size() * sizeof(double)) == 0;
}

double compliance(const FeaSolution& u, const std::vector<NodalLoad>& loads) {
  double c = 0.0;
  for (const NodalLoad& l : loads) c += l.value * u.at(l.node, l.component);
  return c;
}

struct Solve {
  FeaSolution u;
  CgInfo info;
  bool threw = false;
  std::vector<int> dropped;
  long long engaged = 0;
};

// One trajectory-style solve: a fresh run, the run's frozen mask registered and
// the island permit held, exactly as plsm_optimize's / simp's trajectory solves
// hold them. Capped so a red run cannot hang the test.
Solve solve(const Fixture& F) {
  Solve s;
  topopt::fea_matfree_reset_mg_stagnation_latch();
  topopt::FeaIslandKeepMask keep(&F.frozen);
  topopt::FeaIslandDropPermit permit;
  try {
    s.u = topopt::fea_solve_mgcg_matfree(F.g, F.ey, kNu, F.bcs, F.loads, 1e-8,
                                         /*max_iterations=*/40000, &s.info);
  } catch (const topopt::SolverNonConvergence&) {
    s.threw = true;
  }
  s.dropped = topopt::fea_matfree_last_dropped_islands();
  s.engaged = topopt::fea_matfree_mg_safe_engagements();
  return s;
}

}  // namespace

int main() {
  const Fixture clean = make_fixture(false);
  const Fixture F = make_fixture(true);
  std::printf("      fixture: %dx%dx%d, %d loose pieces planted (%lld voxels): %d bars "
              "of 63 voxels, %d hinged pairs, %d frozen\n",
              F.g.nx, F.g.ny, F.g.nz, F.pieces, F.voxels, F.big, F.hinged,
              F.frozen_pieces);
  check(F.pieces >= 250 && F.big >= 10 && F.hinged >= 20 && F.frozen_pieces == 1,
        "setup: ~300 loose pieces, with > 27-voxel ones, hinged pairs and a frozen one");

  // The reference: the beam alone.
  const Solve ref = solve(clean);
  std::printf("      clean beam: used_mg=%d converged=%d mg cycles=%d its=%d "
              "safe engaged=%lld threw=%d\n",
              ref.info.used_multigrid ? 1 : 0, ref.info.converged ? 1 : 0,
              ref.info.mg_cycles_attempted, ref.info.iterations, ref.engaged,
              ref.threw ? 1 : 0);
  check(!ref.threw && ref.info.converged && ref.info.used_multigrid,
        "setup: the clean beam converges on multigrid");

  const Solve s = solve(F);
  long long planted_dropped = 0, other_dropped = 0;
  for (int e : s.dropped)
    (F.planted[static_cast<std::size_t>(e)] ? planted_dropped : other_dropped) += 1;
  std::printf("      with the pieces: used_mg=%d converged=%d mg cycles=%d its=%d "
              "safe engaged=%lld threw=%d ; solved at the floor: %lld of %lld planted "
              "voxels, %lld others ; compliance %.12g vs clean %.12g\n",
              s.info.used_multigrid ? 1 : 0, s.info.converged ? 1 : 0,
              s.info.mg_cycles_attempted, s.info.iterations, s.engaged,
              s.threw ? 1 : 0, planted_dropped, F.voxels, other_dropped,
              s.threw ? 0.0 : compliance(s.u, F.loads), compliance(ref.u, clean.loads));
  check(planted_dropped == F.voxels && other_dropped == 0,
        "L1: every planted loose voxel (big, hinged and frozen ones included) is "
        "solved at the floor modulus, and nothing else");
  check(!s.threw && s.info.converged && s.info.used_multigrid,
        "L2: the solve converges on multigrid (no Jacobi-CG fallback)");
  check(!s.threw && bit_identical(s.u, ref.u) &&
            s.info.mg_cycles_attempted == ref.info.mg_cycles_attempted,
        "L3: it is bit-identical to the beam with no pieces, in the same MG cycles");

#ifdef TOPOPT_LOOSE_PIECE_RULE
  {
    // The census, as every solve computes it.
    topopt::FeaIslandKeepMask keep(&F.frozen);
    const auto C = topopt::fea_detail::mg_island_census(F.g, F.ey, F.bcs, F.loads);
    std::printf("      census: %d pieces, %d loose (%lld voxels, largest %d), %d frozen "
                "loose, majority loose %d, flood fill %.2f ms\n",
                C.pieces, C.unanchored, C.unanchored_voxels, C.largest_unanchored,
                C.frozen_loose, C.majority_loose ? 1 : 0, C.ms);
    check(C.unanchored == F.pieces && C.pieces == F.pieces + 1 &&
              C.unanchored_voxels == F.voxels && C.largest_unanchored == 63 &&
              C.frozen_loose == 1,
          "L1 census: one anchored piece (the beam); every planted piece loose, "
          "a hinged pair counted as its two face-connected pieces, the frozen one "
          "counted");
    // 4,617 loose voxels against the beam's 3,136: more than half the solid is
    // loose, which the run REPORTS (once) and still cleans.
    check(C.majority_loose && st_warned_once(),
          "L1: more than half the solid loose is a reported warning (once per run), "
          "not a refusal to clean");
    const auto& st = topopt::fea_detail::mg_loose_stats();
    std::printf("      last run: %lld solve(s) scanned, %lld with loose pieces, flood "
                "fill %.2f ms\n", st.scanned, st.with_loose, st.ms_total);
  }
  {
    // L4: FACE connection, not proximity. A 3x3x3 cube touching the beam only at
    // a CORNER and a 3-voxel bar touching it only along an EDGE are hinges: LOOSE.
    // A 2x2x2 cube sharing a FACE with the beam is part of it. A single voxel on
    // a loaded node is anchored by the load; a voxel one voxel clear is loose.
    Fixture K = make_fixture(false);
    for (int k = 19; k < 22; ++k)
      for (int j = 19; j < 22; ++j)
        for (int i = 30; i < 33; ++i) K.ey[K.g.index(i, j, k)] = 0.5 * kE0;
    const std::size_t e_corner = K.g.index(30, 19, 19);  // corner-touches (29,18,18)
    for (int i = 40; i < 43; ++i) K.ey[K.g.index(i, 11, 11)] = 0.5 * kE0;
    const std::size_t e_edge = K.g.index(41, 11, 11);  // edge-touches (41,12,12)
    for (int k = 13; k < 15; ++k)
      for (int j = 19; j < 21; ++j)
        for (int i = 20; i < 22; ++i) K.ey[K.g.index(i, j, k)] = 0.5 * kE0;
    const std::size_t e_face = K.g.index(20, 19, 13);  // shares a face with (20,18,13)
    const std::size_t e_loaded = K.g.index(40, 2, 2);
    K.ey[e_loaded] = 0.5 * kE0;
    K.loads.push_back({topopt::fea_node_index(K.g, 40, 2, 2), 0, 1e-3});
    const std::size_t e_clear = K.g.index(50, 20, 14);  // y = 20: one voxel clear
    K.ey[e_clear] = 0.5 * kE0;
    const auto C = topopt::fea_detail::mg_island_census(K.g, K.ey, K.bcs, K.loads);
    bool corner_dropped = false, edge_dropped = false, face_kept = true,
         loaded_kept = true, clear_dropped = false;
    for (int e : C.drop) {
      const std::size_t u = static_cast<std::size_t>(e);
      if (u == e_corner) corner_dropped = true;
      if (u == e_edge) edge_dropped = true;
      if (u == e_face) face_kept = false;
      if (u == e_loaded) loaded_kept = false;
      if (u == e_clear) clear_dropped = true;
    }
    std::printf("      L4 census: %d pieces, %d loose (%lld voxels)\n", C.pieces,
                C.unanchored, C.unanchored_voxels);
    check(corner_dropped && edge_dropped && face_kept && loaded_kept && clear_dropped &&
              C.unanchored == 3 && C.unanchored_voxels == 27 + 3 + 1 && C.pieces == 5,
          "L4: a corner-hinged cube and an edge-hinged bar are LOOSE; a face-joined "
          "cube is part of the anchored body; a loaded voxel is anchored; a voxel one "
          "voxel clear is loose");
    // The same rule on a DESIGN (fea_loose_pieces, the strengthen hand-off's).
    std::vector<char> solid(K.g.voxel_count(), 0);
    for (std::size_t e = 0; e < solid.size(); ++e) solid[e] = K.ey[e] >= 1.0 ? 1 : 0;
    const topopt::LoosePieceCensus D =
        topopt::fea_loose_pieces(K.g, solid, K.bcs, K.loads);
    check(D.pieces == C.pieces && D.loose == C.unanchored &&
              D.loose_voxel == C.drop,
          "L4: fea_loose_pieces classifies a design exactly as the solve does");
  }
#endif

  // ---------------------------------------------------------------------------
  // N: THE SAFETY NET (ruling 2026-10-25, item 5; limits per the review of
  // 2026-10-26). A Jacobi-CG solve past its WALL CLOCK stops the job: it throws
  // SolverStopped, "stopped: the solver did not converge", which is NOT a
  // SolverNonConvergence (so no rung-rejection catch absorbs it). Reaching the
  // iteration CAP — its own or the caller's — is a SolverNonConvergence. Fixture: an 8^3
  // box of floor material (1e-9 E0) clamped at x = 0, holding a 2 x 2 solid bar
  // that its tip load anchors but that only the floor supports (a 1e9 contrast,
  // asked for an unreachable 1e-100, so CG runs to its cap), the safe retry off
  // so the fallback runs.
  // RED on 322b1c78: no time limit at all.
  // ---------------------------------------------------------------------------
  {
    VoxelGrid g;
    g.nx = g.ny = g.nz = 8;
    g.spacing = 1.0;
    g.origin = Vec3{0, 0, 0};
    g.tags.assign(512, VoxelTag::Interior);
    std::vector<double> ey(512, kFloor);
    for (int i = 2; i < 8; ++i)
      for (int k = 3; k < 5; ++k)
        for (int j = 3; j < 5; ++j) ey[g.index(i, j, k)] = kE0;
    std::vector<DirichletBC> bcs;
    for (int c = 0; c <= 8; ++c)
      for (int b = 0; b <= 8; ++b)
        for (int d = 0; d < 3; ++d)
          bcs.push_back({topopt::fea_node_index(g, 0, b, c), d, 0.0});
    std::vector<NodalLoad> loads;
    for (int c = 3; c <= 5; ++c)
      for (int b = 3; b <= 5; ++b)
        loads.push_back({topopt::fea_node_index(g, 8, b, c), 2, -1.0});
    struct Outcome {
      bool stopped = false, nonconv = false, converged = false;
      std::string what;
    };
    auto attempt = [&](int cap, bool plain) {
      Outcome o;
      topopt::fea_matfree_reset_mg_stagnation_latch();
      topopt::fea_matfree_set_mg_safe_retry(false);
      try {
        CgInfo ci;
        if (plain)
          topopt::fea_solve_cg_matfree(g, ey, kNu, bcs, loads, 1e-100, cap, &ci);
        else
          topopt::fea_solve_mgcg_matfree(g, ey, kNu, bcs, loads, 1e-100, cap, &ci);
        o.converged = true;
        char b[160];
        std::snprintf(b, sizeof b, "(used_mg=%d its=%d res=%.3e)", ci.used_multigrid ? 1 : 0,
                      ci.iterations, ci.residual);
        o.what = b;
      } catch (const topopt::SolverNonConvergence& e) {
        o.nonconv = true;
        o.what = e.what();
      } catch (const std::runtime_error& e) {
        o.what = e.what();
        o.stopped =
            o.what.rfind("stopped: the solver did not converge", 0) == 0;
      }
      topopt::fea_matfree_set_mg_safe_retry(true);
      std::printf("      %s, cap %d: stopped=%d nonconvergence=%d converged=%d : %s\n",
                  plain ? "plain Jacobi-CG" : "MG fallback", cap, o.stopped ? 1 : 0,
                  o.nonconv ? 1 : 0, o.converged ? 1 : 0, o.what.c_str());
      return o;
    };
    const Outcome a = attempt(0, false);
    check(a.nonconv && !a.stopped,
          "N1: the MG solve's Jacobi-CG fallback at its own cap is a "
          "SolverNonConvergence (a rejected rung; review 2026-10-26), not a stop");
    const Outcome b = attempt(0, true);
    check(b.nonconv && !b.stopped,
          "N1: so is the plain matrix-free Jacobi-CG at its own cap");
    const Outcome c = attempt(50, false);
    check(c.nonconv && !c.stopped,
          "N2: a caller's explicit cap keeps today's SolverNonConvergence");
#ifdef TOPOPT_LOOSE_PIECE_RULE
    // The time limit (TEST ONLY override: 1 microsecond, so the first poll, at
    // 16 iterations, trips it). Only the wall clock throws SolverStopped.
    topopt::fea_detail::mf_test_safety_net_ms(1e-3);
    const Outcome t = attempt(0, false);
    const Outcome tp = attempt(0, true);
    const Outcome tc = attempt(100000, false);  // even under a caller's cap
    topopt::fea_detail::mf_test_safety_net_ms(0.0);
    check(t.stopped && tp.stopped && tc.stopped &&
              t.what.find("time limit") != std::string::npos,
          "N3: past its time limit a Jacobi-CG solve STOPS the job (MG fallback, "
          "plain CG, and under a caller's cap too)");
    check(topopt::fea_detail::mf_safety_net_ms() == topopt::kSolverSafetyNetMs &&
              topopt::kSolverSafetyNetMs == 45.0 * 60.0 * 1000.0 &&
              topopt::fea_detail::kFallbackIterCap == 250000,
          "N3: the shipped backstop is 45 minutes of solving per Jacobi-CG solve and "
          "an iteration cap of min(max(1000, 2 ng), 250,000)");

    // N4: the net is polled between CG iterations, so a long setup inside the
    // solve must stand down at its deadline: GenEO's basis build (877 s on his
    // Carriage Arms at res 96; run A of this task sat in it past the limit).
    // With the solve's deadline already passed the build returns no basis;
    // POSITIVE CONTROL: with no deadline the same build succeeds.
    {
      namespace fd = topopt::fea_detail;
      const bool was = fd::geneo_set_enabled(true);
      auto engage = [&](double deadline) {
        fd::geneo_reset();
        fd::MatfreeReduced m = fd::mf_build_reduced(g, 1.0, kNu, bcs, loads, &ey,
                                                    "test_loose_pieces", nullptr);
        fd::MfSolveContext ctx;
        ctx.grid = &g;
        ctx.elem_youngs = &ey;
        ctx.youngs_modulus = 1.0;
        ctx.poisson = kNu;
        fd::geneo_solve_begin(m, ctx);
        const double prev = fd::mf_safety_net_deadline();
        fd::mf_safety_net_deadline() = deadline;
        const bool built = fd::geneo_engage_now(m, ctx, 500);
        fd::mf_safety_net_deadline() = prev;
        return std::make_pair(built, fd::geneo_basis_builds());
      };
      const auto late = engage(fd::mf_steady_ms() - 1.0);
      const auto free_run = engage(0.0);
      fd::geneo_reset();
      fd::geneo_set_enabled(was);
      std::printf("      GenEO build past the deadline: built=%d (builds %lld) ; with no "
                  "deadline: built=%d (builds %lld)\n",
                  late.first ? 1 : 0, late.second, free_run.first ? 1 : 0,
                  free_run.second);
      check(!late.first && free_run.first,
            "N4: GenEO's basis build stands down at the solve's safety-net deadline "
            "(POSITIVE CONTROL: it builds with none)");
    }
#endif
  }

  if (g_failures == 0) std::printf("loose_pieces: all checks passed\n");
  else std::printf("loose_pieces: %d check(s) FAILED\n", g_failures);
  return g_failures == 0 ? 0 : 1;
}
