#ifndef TOPOPT_LATTICE_ALGORITHM_HPP
#define TOPOPT_LATTICE_ALGORITHM_HPP

// ★ THE LATTICE ALGORITHM SELECTOR (task 2026-08-21-organic-lattice, §4).
//
// THREE ALGORITHMS, ALL CALLABLE, so a UI can be built against them separately. This
// enum is ORTHOGONAL to `CellSizeMode` (cell_plan.hpp): the mode says HOW THE CELL IS
// CHOSEN (fixed / auto / swept / fit), this says WHAT KIND OF LATTICE IS LAID DOWN.
//
//   DOUBLED — the DYADIC LADDER. cell_plan.hpp. Cells of different size meet at SHARED
//             NODES because the admissible sizes are S0 * 2^L on an aligned, 2:1
//             balanced octree, so a coarse cell's nodes nest in the fine grid. That
//             nesting IS the transition handling, and it is why the two alternatives
//             (conformal warp, banded regions) were measured and rejected in PR 235.
//             ★ THE DEFAULT, so every existing job is byte-identical.
//   STEPPED — ONE CELL PER DECLARED REGION, taken from the derivation VERBATIM, with
//             NO TRANSITION HANDLING: regions abut at whatever cells they each derived
//             and the nodes do not line up. It is `Fit` WITHOUT THE DYADIC SNAP.
//             ★ THE COST OF THAT IS A REAL NUMBER AND THIS ALGORITHM MEASURES IT —
//             see `LatticeSteppedStats::floating_ends`. PR 235 rejected banded regions
//             precisely because an unshared node is a floating strut end; STEPPED does
//             not pretend otherwise, it counts them.
//   ORGANIC — struts TRACED along the stress field, spacing as the input, cell size
//             derived from the spacing. topopt/organic_lattice.hpp.
//             ★ AESTHETIC INTENT ONLY — see that header's `tensor_out_of_regime`.
//
// ★ WHAT ALL THREE SHARE, AND IT IS NOT NEGOTIABLE (§4a): every one of them emits a
// PER-VOXEL RELATIVE DENSITY. Certification, min-feature, the frozen and protect masks,
// the clearance keep-outs and every exporter read one and only one. That contract is
// what makes the selector cheap: nothing downstream branches on the algorithm.

#include <string>
#include <vector>

namespace topopt {

enum class LatticeAlgorithm { Doubled, Stepped, Organic };

// "doubled" | "stepped" | "organic". Throws std::logic_error for an enum value with no
// name — a new case must be named here before anything can serialize it, never a
// silent fallback (the same posture cell_size_mode_name takes).
const char* lattice_algorithm_name(LatticeAlgorithm a);

// Parse an algorithm name; false (and `out` untouched) for anything else — a job
// schema never silently falls back to an algorithm the user did not ask for.
bool lattice_algorithm_from_name(const char* name, LatticeAlgorithm& out);

// Every algorithm name, in enum order — the one source a picker reads, so a UI set can
// never drift from this enum.
std::vector<std::string> lattice_algorithm_names();

}  // namespace topopt

#endif  // TOPOPT_LATTICE_ALGORITHM_HPP
