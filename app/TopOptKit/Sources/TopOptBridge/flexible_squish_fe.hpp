// flexible_squish_fe — the app's setup of ONE squeeze group's 3D squish, solved by core's
// existing matrix-free MG-CG (task 2026-09-29-flexible-screens, round 5 batch G). PRIVATE to
// the bridge target (not under include/, so not in the Swift module): the entry point is
// `flexible_scene_squish_solve` in flexible_bridge.cpp, which copies what the solve needs out
// of the scene under its lock and calls `solve` below WITHOUT the lock (the Settings page's
// design calls are never blocked for seconds). Core itself is not edited.
#pragma once

#include <vector>

#include "FlexibleBridge.hpp"
#include "topopt/face_region.hpp"
#include "topopt/flexible/data.hpp"
#include "topopt/flexible/faces.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

namespace topoptbridge {
namespace squishfe {

// One pressed face: its resolved region (the slab's faces and cuts) and core's stack (the
// frame, the columns the pressures belong to, the linked other end).
struct Press {
  topopt::ResolvedFaceRegion region;
  topopt::flexible::Stack stack;
};

struct Setup {
  topopt::VoxelGrid grid;                  // the scene's grid (a copy)
  const topopt::StepModel* model = nullptr;  // the scene's part; immutable after open
  std::vector<Press> pressed;              // parallel to the request's `pressed`
  std::vector<topopt::ResolvedFaceRegion> resting;
  std::vector<int32_t> resting_missing;
};

FlexSquishSolution solve(const Setup& s, const FlexSquishRequest& req,
                         const topopt::flexible::FlexibleData& data);
double modulus(const FlexSquishLaw& law, const topopt::flexible::FlexibleData& data, double rho,
               double strain, double skin_frac, int control);
int coarsen(int nx, int ny, int nz);

// ★ BATCH N: the squish solved in STEPS (material-nonlinear). `step_begin` builds the problem ONCE
// (out.session > 0; a failure is a value, malformed input throws); each `step` solves it at a load
// factor by damped secant iterations, warm-started from the last step; `step_end` frees it.
FlexSquishSolution step_begin(const Setup& s, const FlexSquishRequest& req,
                              const topopt::flexible::FlexibleData& data, const FlexSquishStepOptions& opt);
FlexSquishSolution step(int64_t session, double load_factor, int max_iterations, double tolerance);
void step_end(int64_t session);
int64_t live_sessions();
double step_modulus(const FlexSquishLaw& law, const topopt::flexible::FlexibleData& data, double rho,
                    double strain, double skin_frac, const FlexSquishStepOptions& opt);

}  // namespace squishfe
}  // namespace topoptbridge
