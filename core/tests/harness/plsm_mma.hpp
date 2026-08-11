// plsm_mma.hpp — ★ A SHIM. THE COEFFICIENT-SPACE MMA STEP NOW LIVES IN CORE.
//
// PR 324 wrote this step for ARM 2. Task 2026-08-10-plsm-production moved it into
// `core/include/topopt/plsm_mma.hpp`, because the PRODUCTION parametric optimiser
// drives its coefficients with the same step and a production copy would be a
// second MMA in the repository. The body is `topopt::plsm_mma_update` and nothing
// here can drift from it — including the sign convention (beta = -alpha, so
// "design up" means "material in" and core's MMA signs carry over unchanged).
//
// Included from inside an anonymous namespace, so the core header it aliases is
// included at FILE SCOPE by every includer and keeps external linkage.

#ifndef TOPOPT_TESTS_HARNESS_PLSM_MMA_HPP_
#define TOPOPT_TESTS_HARNESS_PLSM_MMA_HPP_

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

using PlsmMmaState = topopt::PlsmMmaState;
using topopt::plsm_mma_update;

#endif  // TOPOPT_TESTS_HARNESS_PLSM_MMA_HPP_
