// Organic strength, CUT 1 stage C1 (agent-scratch/lattice-rebuild/stage1/strength-build-plan.md, section 7): the break
// check on the printed shape itself. The print file is voxelised at a fine grid (0.2 mm by default), the part's fixed
// and loaded faces are found on that grid, one linear solve of the printed material is made at the working load, each
// material voxel's stress is smoothed over a ball of material, and its load multiple is read against the material's
// directional limit (along the layers the yield, across them the yield x z_knockdown, by the rise of the tension
// direction against the build direction; compression the yield). The first break is the smallest multiple.
//
// A point counts as JUDGED (resolved) only where the member through it is at least `min_voxels_across` voxels thick
// (the largest ball of material through the point; the study's S4 rule). The verdict has three values:
//   "fail"       the first break over judged points is under the pass line;
//   "not_proven" it is not, but a place too thin to judge reads under the pass line (by its own reading, or, for a
//                post, by its file section), or no point is judged at all;
//   "pass"       otherwise.
// Not wired into the file job here (stage C2 does that). Nothing in this file changes any existing check.
#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/step.hpp"

namespace topopt::lattice_layout {

// A bar of the lay as the file holds it (model frame), and a post as the print check laid it.
struct BreakBar {
  Vec3 a{}, b{};
  double width = 0.0;
};
struct BreakPost {
  double x = 0.0, y = 0.0;              // its axis
  double z_bottom = 0.0, z_top = 0.0;   // as laid (MeshSpec::Post)
  double width = 0.9;                   // the square it was laid with (MeshSpec::post_mm); the part's faces may trim it
};
struct BreakLoad {
  std::vector<int> faces;   // the part's face ids
  Vec3 force{};             // N, shared by area over the faces' voxel faces
};

struct BreakAsk {
  const TriangleMesh* print = nullptr;   // the print file (model frame)
  const StepModel* part = nullptr;       // the part, for its faces (the same frame)
  std::vector<int> fixed_faces;          // held in every direction
  std::vector<BreakLoad> loads;
  std::vector<BreakBar> bars;            // the kept bars (classes only)
  std::vector<BreakPost> posts;
  // The material (the job's own entry: yield_strength_mpa, z_knockdown, poisson, youngs_modulus_mpa).
  double youngs_mpa = 0.0, poisson = 0.3, yield_mpa = 0.0, z_knockdown = 1.0;
  Vec3 up{0.0, 0.0, 1.0};               // the build direction
  double pass_line = 1.5;               // the job's safety margin
  double voxel_mm = 0.2;                // the grid (mark 6 will compare 0.1 mm)
  // The grid is anchored at the PART's box low corner + grid_shift x voxel_mm (0: on the part's box; the study's blocks
  // were solved at -0.5, -0.5, 0), and extended by whole voxels to hold the whole print.
  Vec3 grid_shift{0.0, 0.0, 0.0};
  double smooth_mm = 0.9;               // the smoothing ball's radius
  int min_voxels_across = 3;            // the judged (resolved) gate
  double near_post_mm = 2.0;            // the class "solid near a post's end"
  double tolerance = 1e-2;              // the solve's relative residual
  int max_rounds = 15000;               // a solve that does not settle within it gives no number
  std::size_t places_listed = 20;       // at most this many not-judged places under the pass line
};

// What the check will need before it solves: the grid, the material voxels, and the bytes at 3,200 B per material voxel
// plus 40 B per box voxel (the plan's first estimate, to be measured).
struct BreakSize {
  int nx = 0, ny = 0, nz = 0;
  std::size_t box_voxels = 0, material_voxels = 0;
  double bytes = 0.0;
};
BreakSize organic_break_size(const BreakAsk& ask);

struct BreakPoint {
  bool found = false;
  double multiple = 0.0;        // of the working load, at which the point reaches its limit
  Vec3 at{};                    // the voxel centre, model frame
  std::string cls;              // "vine", "post", "solid_near_post", "solid"
  int post = -1;                // the post's index in BreakAsk::posts, for class "post"
  double thickness_voxels = 0.0;
  bool resolved = false;
  std::string by;               // "tension" or "compression"
};
struct BreakClass {
  std::string cls;
  int post = -1;
  BreakPoint all, resolved;     // the smallest over all its points, and over its judged points
  double section_multiple = 0.0;   // posts: the mid-height force over the post's file section (0: not read)
  double section_mm2 = 0.0, section_force_n = 0.0;
};
struct BreakResult {
  bool ok = false;              // false: no number (the solve did not settle, or the ask is unusable); `why` says
  std::string why;
  std::string verdict;          // "pass", "fail", "not_proven"
  BreakPoint first_all, first_resolved;
  std::vector<BreakClass> classes;
  std::vector<BreakPoint> not_judged_under;   // places too thin to judge that read under the pass line
  BreakSize size;
  int rounds = 0;
  bool converged = false;
  double seconds = 0.0, peak_mb = 0.0;
  std::string json;             // the "break" block, an object
};
BreakResult organic_break_check(const BreakAsk& ask);

// The limit law (exposed for its test): the multiple of a smoothed stress state (Voigt xx yy zz xy yz zx) against
// the material's directional limits; `by` gets "tension" or "compression".
double break_multiple(const double voigt[6], double yield_mpa, double z_knockdown, const Vec3& up, std::string* by = nullptr);

// The member thickness at voxel (i, j, k) of a material mask, in voxels: the largest 2 DT(c) over material voxels c
// whose inscribed ball holds it (DT = distance to the nearest non-material voxel centre, less half a voxel), searched
// within `reach` voxels (exposed for its test).
double break_member_thickness(const std::vector<char>& mat, int nx, int ny, int nz, int i, int j, int k, int reach = 6);

}  // namespace topopt::lattice_layout
