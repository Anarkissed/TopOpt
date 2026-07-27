// Device-real S1: FROZEN MEANS FROZEN on a REAL variant mesh from the L-bracket
// run (not a synthetic one). Import the STL, freeze a Bolt bore region, smooth at
// every strength, assert every frozen vertex is bit-identical (doubles, memcmp).
#include "topopt/clearance.hpp"
#include "topopt/mesh.hpp"
#include "topopt/smooth.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"
#include <cstdio>
#include <cstring>
using namespace topopt;
int main(int argc, char** argv) {
  TriangleMesh m = import_stl_file(argv[1]);
  // grid to drive the min-feature constraint (as the CLI does)
  VoxelGrid grid = voxelize(m, 48);
  Vec3 lo, hi; bounding_box(m, lo, hi);
  // A Bolt bore through the part centre along Z, radius ~1/6 of the span.
  ManualClearanceGeometry g; g.kind = ClearanceKind::Bolt;
  g.axis_point = Vec3{(lo.x+hi.x)/2, (lo.y+hi.y)/2, lo.z};
  g.axis_dir = Vec3{0,0,1};
  g.radius_mm = (hi.x-lo.x)/6.0;
  g.half_length_mm = (hi.z-lo.z);
  ClearanceParams p; p.kind = ClearanceKind::Bolt;
  ClearanceGeometry region = resolve_clearance_manual(g, p);
  SmoothConstraints c; c.freeze_regions = {region}; c.freeze_tol_mm = 0.75;
  c.min_feature_grid = &grid;
  auto mask = compute_freeze_mask(m, c.freeze_regions, c.freeze_tol_mm);
  size_t nf=0; for(char f:mask) nf+=f?1:0;
  printf("device mesh: %zu verts, %zu triangles; frozen region = %zu verts\n",
         m.vertices.size(), m.triangles.size(), nf);
  int fails=0;
  for (double s : {0.1,0.25,0.5,0.75,1.0}) {
    SmoothResult r = constrained_taubin_smooth(m, taubin_params_for_strength(s), c);
    size_t moved=0, frozen_changed=0;
    for (size_t v=0; v<m.vertices.size(); ++v) {
      bool same = std::memcmp(&r.mesh.vertices[v], &m.vertices[v], sizeof(Vec3))==0;
      if (mask[v]) { if(!same) ++frozen_changed; }
      else if (!same) ++moved;
    }
    printf("  strength %.2f: frozen_changed=%zu (MUST be 0)  free_moved=%zu\n",
           s, frozen_changed, moved);
    if (frozen_changed!=0) ++fails;
  }
  printf("%s\n", fails==0 ? "S1 DEVICE-REAL PASS: every frozen vertex bit-identical at every strength"
                          : "S1 FAIL");
  return fails;
}
