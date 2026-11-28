// test_to_stage4_pocket — TO rebuild stage 4, test I (the DETECTION half): a
// sealed pocket is caught on a made 24^3 solid cube.
//
// Two readers of the same rule are checked against each other on every case:
// plsm_void_topology (plsm_topology.hpp, the counters every parametric run
// reports) and sealed_pocket_summary (pipeline.hpp, stage 4 "pocket": adds the
// largest pocket). The rule, from plsm_topology.hpp's own comments: the void walk
// is 6-CONNECTED (face neighbours only) and the outside is the grid's six
// boundary planes; "two voxels meeting only at an edge or a corner share ZERO
// AREA; nothing drains through a measure-zero contact".
//
// What this does NOT reach: the per-version report block and the [pocket] log
// line are written inside minimize_plastic after a full solve; exercising them
// needs a CLI run, which this unit test does not do.

#include <cmath>
#include <cstdio>
#include <vector>

#include "topopt/pipeline.hpp"
#include "topopt/plsm_topology.hpp"

using namespace topopt;

static int g_fail = 0;
static const int N = 24;
static const double H = 0.5;  // mm per voxel: a 12 mm cube, 0.125 mm3 per voxel

struct Cube {
  std::vector<double> occ = std::vector<double>(N * N * N, 1.0);
  std::vector<char> in_part = std::vector<char>(N * N * N, 1);
  void hole(int i0, int i1, int j0, int j1, int k0, int k1) {
    for (int k = k0; k <= k1; ++k)
      for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i) occ[plsm_at(N, N, i, j, k)] = 0.0;
  }
};

static void check(const char* name, const Cube& c, long long want_count,
                  long long want_voxels, long long want_largest) {
  const SealedPocketSummary s = sealed_pocket_summary(N, N, N, H, c.occ, 0.5, c.in_part);
  const PlsmVoidTopology t = plsm_void_topology(N, N, N, H, c.occ, 0.5, c.in_part);
  const double vox = H * H * H;
  const bool ok = s.count == want_count && s.voxels == want_voxels &&
                  s.largest_voxels == want_largest &&
                  std::fabs(s.volume_mm3 - want_voxels * vox) < 1e-12 &&
                  std::fabs(s.largest_mm3 - want_largest * vox) < 1e-12 &&
                  t.sealed_pockets == s.count && t.sealed_voxels == s.voxels;
  std::printf("%-44s %s  count %lld (want %lld), volume %.3f mm3 (want %.3f), "
              "largest %.3f mm3 (want %.3f); topology counters: %lld pocket(s), %lld voxels\n",
              name, ok ? "PASS" : "FAIL", s.count, want_count, s.volume_mm3,
              want_voxels * vox, s.largest_mm3, want_largest * vox, t.sealed_pockets,
              t.sealed_voxels);
  if (!ok) ++g_fail;
}

int main() {
  {  // (i) no cavity
    Cube c;
    check("(i) solid cube, no cavity", c, 0, 0, 0);
  }
  {  // (ii) one enclosed 4^3 cavity in the middle
    Cube c;
    c.hole(10, 13, 10, 13, 10, 13);
    check("(ii) one enclosed 4^3 cavity", c, 1, 64, 64);
  }
  {  // (iii) the same cavity with a 1-voxel channel to the face x = 0
    Cube c;
    c.hole(10, 13, 10, 13, 10, 13);
    c.hole(0, 9, 11, 11, 11, 11);  // ends at (9,11,11), face-next to (10,11,11)
    check("(iii) cavity + 1-voxel channel out", c, 0, 0, 0);
  }
  {  // (iv) two separate cavities: 4^3 and 3^3
    Cube c;
    c.hole(4, 7, 4, 7, 4, 7);
    c.hole(15, 17, 15, 17, 15, 17);
    check("(iv) two cavities (64 + 27 voxels)", c, 2, 91, 64);
  }
  {  // (v-a) the cavity meets an open channel only along an EDGE
    Cube c;
    c.hole(10, 13, 10, 13, 10, 13);
    c.hole(0, 9, 9, 9, 11, 11);  // ends at (9,9,11): shares an edge with (10,10,11)
    check("(v-a) edge-only contact with a way out", c, 1, 64, 64);
  }
  {  // (v-b) the cavity meets an open channel only at a CORNER
    Cube c;
    c.hole(10, 13, 10, 13, 10, 13);
    c.hole(0, 9, 9, 9, 9, 9);  // ends at (9,9,9): shares a corner with (10,10,10)
    check("(v-b) corner-only contact with a way out", c, 1, 64, 64);
  }
  std::printf("(v) rule: face-connected only (plsm_topology.hpp): an edge or corner "
              "contact is NOT a way out, so both stay sealed\n");
  std::printf("done: %d failure(s)\n", g_fail);
  return g_fail == 0 ? 0 : 1;
}
