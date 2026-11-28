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
// Stage C2 wires it into the Organic file-strength path (run_job.cpp: run_lattice_file_strength_organic), after the rod
// check, which stays as it was. A check that cannot be made (too big for the Mac, a solve that does not settle, a load it
// cannot read, a stop) gives verdict "not_checked" with the reason: never a number, never a pass.
#pragma once

#include <atomic>
#include <cstddef>
#include <functional>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/print_frame.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

namespace topopt::lattice_layout {

// C7, THE LOAD-PATH RULE (a check constant, not a job setting): a number is shown only when every load path is
// resolved. A post carrying over this share of the load whose shaft or an end joint is not resolved, or not-resolved
// material holding over this share of the strain energy, gives "not_proven" (the post or the largest region named).
constexpr double kBreakLoadPathShare = 0.05;
// C8, RULE BY CORES (the lead's design), on the 0.1 mm samples, everything scaling with the voxel:
//  - CORE: material at least r from the outside, r = min_voxels_across / 2 voxels (1.5 voxels: 0.3 mm at 0.2 mm).
//  - THICK: material within r of CORE (the opening by a ball of diameter 3 voxels); THIN: material not THICK.
//  - FAR: material farther than r + d from CORE, d = kBreakFarMarginVoxels voxels (1.25: 0.25 mm at 0.2 mm), which
//    covers the sliver an opening removes at a square edge (0.12 mm) and at a cube's corner (0.22 mm).
//  - A voxel is resolved (THICK) when at least half of its filled samples are THICK. BODIES = the face-connected
//    components of THICK voxels. Each face-connected THIN region is (A) a SLIVER (no FAR material, touching at most one
//    BODY: part of that body's surface, left out of the load-path measures), (B) a THIN MEMBER (holds FAR material:
//    measured by the energy share and the force through it), or (C) a CONNECTOR (no FAR material, touching two or more
//    BODIES, e.g. a kissing contact or a short joint: measured by the force through it).
//  Known limit: a thin patch in parallel with a thick bridge between the same two blocks makes ONE body, so the patch is
//  a sliver and is not measured.
constexpr double kBreakFarMarginVoxels = 1.25;

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
  // C2. The print frame the print, the part and `up` are in (off: the model frame); every position and direction the
  // block reports is written back in the model frame.
  PrintFrame frame;
  // C2 (P4): more ups to read the same smoothed stresses against (the print-orientation candidates), no new solve.
  std::vector<Vec3> other_ups;
  // C2, the size guard: the bytes the check may need at most. 0 = 40 % of the machine's physical memory, read when it
  // runs. Set only by a test (the oversize mark); the product never sets it.
  double memory_limit_bytes = 0.0;
  // A reading for the record only (the review's question 1.6), never in the verdict or the block: also smooth over the
  // material CONNECTED to the voxel inside its ball, and give that first break in BreakResult::connected_*.
  bool also_connected_ball = false;
  // A TEST-ONLY input (C3 item b, the study's voxels at matched faces): the material voxels on the check's own grid,
  // given the grid (origin, spacing, size); null = the product voxeliser. The file job never sets it.
  std::function<std::vector<char>(const VoxelGrid&)> material_override;
  // C2: progress lines ("checking its strength: ...") and the job's stop flag, read between the steps (the solver
  // itself takes no stop).
  void (*said)(const char*) = nullptr;
  const std::atomic<bool>* stop = nullptr;
};

// What the check will need before it solves: the grid, the material voxels, and the bytes at 3,200 B per material voxel
// plus 40 B per box voxel (the plan's first estimate, to be measured). The material is COUNTED row by row (the product
// voxeliser's own rule), never laid out in a full box, so a part far too big is turned away before any large allocation.
struct BreakSize {
  int nx = 0, ny = 0, nz = 0;
  std::size_t box_voxels = 0, material_voxels = 0;
  double bytes = 0.0;
  double limit_bytes = 0.0;     // the guard (organic_break_check fills it)
};
// 40 % of the machine's physical memory, read now (sysconf); 0 when it cannot be read.
double break_memory_limit_bytes();
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
  std::string json;             // the "break" block, an object (also when not checked: then with the reason)
  std::string not_checked;      // not ok: "too_big", "did_not_settle", "no_load", "stopped", "error"
  struct UpBreak { Vec3 up{}; double judged = 0.0, all = 0.0; };
  std::vector<UpBreak> by_up;
  // C7, the load-path rule: per post its share of the load and whether its shaft and its two end joints are resolved;
  // the share of the strain energy in not-resolved material, in total and in its largest connected region (and where);
  // and why the verdict is not_proven (empty otherwise).
  struct PostPath { double share = 0.0; bool shaft = true, foot = true, top = true; };
  std::vector<PostPath> post_paths;
  double unresolved_energy_share = 0.0, largest_unresolved_share = 0.0;
  Vec3 largest_unresolved_at{};
  std::size_t largest_unresolved_voxels = 0;
  // C8, (iii): each not-resolved region's load share (the largest net force through any one-voxel slice of it along
  // any axis, over the applied load), with its energy share, place and voxels; those over 1 %, largest first, at most 10.
  // A region over kBreakLoadPathShare gives not_proven ("unresolved_joint").
  struct Region { double load_share = 0.0, energy_share = 0.0; Vec3 at{}; std::size_t voxels = 0, first = 0, bodies = 0; bool member = true; };
  std::vector<Region> joint_regions;
  std::size_t unresolved_voxels = 0;   // material voxels the gate does not judge
  std::size_t sliver_regions = 0, sliver_voxels = 0, member_regions = 0, connector_regions = 0;   // C8, rule by cores
  std::vector<std::string> not_proven_because;
  // also_connected_ball: the voxels whose ball holds material not connected to them inside it, and the first breaks
  // (judged, all points) smoothed over the connected material only.
  std::size_t connected_split_voxels = 0;
  BreakPoint connected_judged, connected_all;   // per BreakAsk::other_ups (the ask's frame): the first break, judged and over all points
};
BreakResult organic_break_check(const BreakAsk& ask);

// The limit law (exposed for its test): the multiple of a smoothed stress state (Voigt xx yy zz xy yz zx) against
// the material's directional limits; `by` gets "tension" or "compression".
double break_multiple(const double voigt[6], double yield_mpa, double z_knockdown, const Vec3& up, std::string* by = nullptr);

// The member thickness at voxel (i, j, k) of a material mask, in voxels: the largest 2 DT(c) over material voxels c
// whose inscribed ball holds it (DT = distance to the nearest non-material voxel centre, less half a voxel), searched
// within `reach` voxels (exposed for its test).
// The judged (resolved) mask the verdict reads: a material voxel is judged where some material voxel within
// `min_voxels_across` voxels has an inscribed ball (radius = distance to the nearest empty centre less half a voxel) of
// at least min/2 voxels that holds it.
std::vector<char> break_judged(const std::vector<char>& mat, int nx, int ny, int nz, int min_voxels_across);

double break_member_thickness(const std::vector<char>& mat, int nx, int ny, int nz, int i, int j, int k, int reach = 6);

}  // namespace topopt::lattice_layout
